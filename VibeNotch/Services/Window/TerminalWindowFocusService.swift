//
//  TerminalWindowFocusService.swift
//  VibeNotch
//
//  Brings the window that hosts a given agent session to the front.
//
//  The important part is *what to activate*. Walking up the process tree to
//  "the first ancestor whose name looks like a terminal" is not enough:
//
//    - Electron apps spawn helper processes. A Claude session inside Paseo
//      looks like `claude -> /bin/zsh -> Paseo Helper (pid 3356)`, but the
//      window belongs to the main `Paseo` process (pid 1252). Activating the
//      helper does nothing visible.
//    - Some agents have no terminal at all. A WorkBuddy session's pid *is*
//      `/Applications/WorkBuddy AI.app/.../Electron`; its ancestors are other
//      Electron processes and launchd. There is nothing named "terminal" in
//      the chain, yet the user still expects to jump back to that app.
//
//  So we resolve the outermost `.app` bundle along the ancestor chain and
//  match it against NSWorkspace.runningApplications to get the *main* app
//  process. Every strategy activates that app first, which also makes the
//  no-permission / no-match degradation reliable.
//
//  Strategy, best match first:
//    1. tmux + yabai           handled by YabaiController (the caller tries it
//       first so pane switching keeps working where yabai is installed)
//    2. Terminal.app / iTerm2  exact TTY match through their AppleScript
//       dictionaries (a tab/session exposes its tty)
//    3. WezTerm                exact pane match through `wezterm cli list`
//       (tty_name / cwd) + `activate-pane`
//    4. Everything else        activate the host app, then — when Accessibility
//       is granted — raise the window whose title best matches the session's
//       cwd / project name. Covers Paseo, WorkBuddy, kitty, Warp, Ghostty,
//       VS Code, Tabby, ...
//    5. Last resort            just activate the host app
//
//  Nothing here requires yabai, and the app is not sandboxed, so Apple events
//  and the Accessibility API are both available.
//

import AppKit
import ApplicationServices
import Foundation

/// Outcome of a "jump to terminal" action. The UI turns this into a short toast.
enum TerminalFocusResult: Equatable, Sendable {
    /// The exact window/tab hosting the session was brought to the front.
    case focused(terminal: String)
    /// The host app was brought to the front, but the specific window could not
    /// be pinpointed. `needsPermission` tells the UI to point the user at
    /// Accessibility settings.
    case activated(terminal: String, needsPermission: Bool)
    /// Could not work out which app hosts this session at all.
    case noTerminal
    /// Apple events were blocked (Automation permission not granted).
    case noPermission(terminal: String)
}

// MARK: - Service

actor TerminalWindowFocusService {
    static let shared = TerminalWindowFocusService()

    private init() {}

    /// Focus the window/app that hosts `session`.
    ///
    /// - Parameter summary: pre-computed window-title hint. `SessionState`'s
    ///   computed properties are `@MainActor`-isolated under this project's
    ///   default isolation, so the caller supplies it instead.
    func focus(session: SessionState, summary: String? = nil) async -> TerminalFocusResult {
        let tree = ProcessTreeBuilder.shared.buildTree()
        let agentPid = resolveAgentPid(session: session, tree: tree)

        // Resolve the GUI app that owns the window. Fall back to the agent's
        // own application when no anchor process is available (WorkBuddy).
        // `??` takes an autoclosure, so the second await can't live there.
        var host = await resolveHostApp(agentPid: agentPid, tree: tree)
        if host == nil {
            host = await fallbackHost(for: session.source)
        }
        guard let host else { return .noTerminal }

        let kind = classify(host: host)
        let tty = agentPid.flatMap { resolveTTY(session: session, agentPid: $0, tree: tree) }
        let candidates = titleCandidates(session: session, summary: summary)

        switch kind {
        case .terminalApp, .iTerm2:
            if let tty {
                let outcome = await focusViaAppleScript(kind: kind, tty: tty)
                switch outcome {
                case .focused:
                    return .focused(terminal: kind.displayName)
                case .noPermission:
                    await activateApp(pid: host.pid)
                    return .noPermission(terminal: kind.displayName)
                case .noMatch:
                    break
                }
            }
            return await focusWithAccessibility(host: host, kind: kind, candidates: candidates)

        case .wezTerm:
            if let paneTitles = await focusViaWezTerm(
                session: session, tty: tty, candidates: candidates
            ) {
                await activateApp(pid: host.pid)
                // Raise the correct GUI window too (WezTerm can have several).
                _ = raiseBestWindow(
                    terminalPid: host.pid,
                    candidates: dedupe(candidates + paneTitles)
                )
                return .focused(terminal: kind.displayName)
            }
            return await focusWithAccessibility(host: host, kind: kind, candidates: candidates)

        case .paseo, .workBuddy, .generic:
            return await focusWithAccessibility(host: host, kind: kind, candidates: candidates)
        }
    }

    // MARK: - Host app resolution

    /// Plain-value description of the GUI app we want to activate.
    /// `NSRunningApplication` isn't Sendable, so don't carry it across actors.
    private struct HostAppInfo: Sendable {
        let pid: Int
        let bundleId: String?
        let name: String
    }

    /// Walk the ancestor chain and find the outermost `.app` bundle, then
    /// match it against the running apps so we always activate the *main*
    /// process rather than an Electron helper.
    private func resolveHostApp(agentPid: Int?, tree: [Int: ProcessInfo]) async -> HostAppInfo? {
        guard let agentPid else { return nil }

        var bundlePaths: [String] = []
        var legacyTerminalPid: Int?

        var current = agentPid
        var depth = 0
        while current > 1, depth < 24 {
            guard let info = tree[current] else { break }
            if let path = appBundlePath(from: info.command), !bundlePaths.contains(path) {
                bundlePaths.append(path)
            }
            if legacyTerminalPid == nil, TerminalAppRegistry.isTerminal(info.command) {
                legacyTerminalPid = current
            }
            current = info.ppid
            depth += 1
        }

        let terminalPid = legacyTerminalPid
        let paths = bundlePaths   // immutable snapshot for the MainActor closure
        let info: HostAppInfo? = await MainActor.run {
            let running = NSWorkspace.shared.runningApplications

            // Exact bundle-path match first (most reliable).
            for path in paths {
                let fileName = (path as NSString).lastPathComponent
                if let app = running.first(where: {
                    $0.bundleURL?.path == path || $0.bundleURL?.lastPathComponent == fileName
                }) {
                    return Self.makeHostInfo(app)
                }
            }

            // No .app in the chain (rare) — try the legacy terminal pid.
            if let terminalPid,
               let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) {
                return Self.makeHostInfo(app)
            }
            return nil
        }
        return info
    }

    /// Last resort for agents whose process chain is entirely detached from a
    /// GUI app (e.g. a WorkBuddy heartbeat whose pid has already gone away).
    private func fallbackHost(for source: AgentKind) async -> HostAppInfo? {
        let bundleId: String
        switch source {
        case .workBuddy: bundleId = "com.workbuddy.workbuddy-ai"
        case .lmStudio: bundleId = "ai.elementlabs.lmstudio"
        case .claudeCode, .openCode: return nil
        }

        let info: HostAppInfo? = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .first
                .map { Self.makeHostInfo($0) }
        }
        return info
    }

    private static func makeHostInfo(_ app: NSRunningApplication) -> HostAppInfo {
        HostAppInfo(
            pid: Int(app.processIdentifier),
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleURL?.lastPathComponent ?? "Terminal"
        )
    }

    /// Extract the outermost `.app` from a `ps comm` path.
    /// `/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/.../Paseo Helper`
    /// → `/Applications/Paseo.app`.
    private func appBundlePath(from command: String) -> String? {
        guard command.hasPrefix("/") else { return nil }
        var path = ""
        for component in command.split(separator: "/", omittingEmptySubsequences: true) {
            path += "/" + component
            if component.hasSuffix(".app") { return path }
        }
        return nil
    }

    // MARK: - Terminal classification

    private enum TerminalKind {
        case terminalApp
        case iTerm2
        case wezTerm
        case paseo
        case workBuddy
        case generic(String)

        var displayName: String {
            switch self {
            case .terminalApp: return "Terminal"
            case .iTerm2: return "iTerm2"
            case .wezTerm: return "WezTerm"
            case .paseo: return "Paseo"
            case .workBuddy: return "WorkBuddy"
            case .generic(let name): return name
            }
        }
    }

    private func classify(host: HostAppInfo) -> TerminalKind {
        if let bundleId = host.bundleId {
            switch bundleId {
            case "com.apple.Terminal": return .terminalApp
            case "com.googlecode.iterm2": return .iTerm2
            case "com.github.wez.wezterm": return .wezTerm
            case "sh.paseo.desktop": return .paseo
            case "com.workbuddy.workbuddy-ai": return .workBuddy
            default: break
            }
        }

        let lower = host.name.lowercased()
        if lower.contains("wezterm") { return .wezTerm }
        if lower.contains("paseo") { return .paseo }
        if lower.contains("workbuddy") { return .workBuddy }
        if lower.contains("iterm") { return .iTerm2 }
        if lower.contains("terminal") { return .terminalApp }
        return .generic(host.name)
    }

    // MARK: - Resolving the agent process / TTY

    /// Most providers publish a PID. Polled providers without one (OpenCode)
    /// are resolved by matching their working directory against running agent
    /// processes — those are still descendants of the host app.
    private func resolveAgentPid(session: SessionState, tree: [Int: ProcessInfo]) -> Int? {
        if let pid = session.pid, tree[pid] != nil { return pid }
        guard !session.cwd.isEmpty else { return nil }

        let keywords: [String]
        switch session.source {
        case .openCode: keywords = ["opencode"]
        case .workBuddy: keywords = ["workbuddy", "electron"]
        case .claudeCode: keywords = ["claude"]
        case .lmStudio: keywords = ["lmstudio", "lms"]
        }

        let candidates = tree.values
            .filter { info in keywords.contains { info.command.lowercased().contains($0) } }
            .prefix(12)

        for info in candidates {
            if let cwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: info.pid),
               cwd == session.cwd {
                return info.pid
            }
        }
        return nil
    }

    /// `SessionState.tty` is stored without the `/dev/` prefix. The process
    /// tree and terminal scripting dictionaries use either form, so normalise.
    private func resolveTTY(session: SessionState, agentPid: Int, tree: [Int: ProcessInfo]) -> String? {
        normalizedTTY(session.tty ?? tree[agentPid]?.tty)
    }

    private func normalizedTTY(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "??" else { return nil }
        let value = raw.replacingOccurrences(of: "/dev/", with: "")
        return value.isEmpty ? nil : value
    }

    /// Strings that plausibly appear in a window/tab title.
    private func titleCandidates(session: SessionState, summary: String?) -> [String] {
        var result: [String] = []
        if !session.projectName.isEmpty { result.append(session.projectName) }
        if let summary, !summary.isEmpty { result.append(summary) }

        if !session.cwd.isEmpty {
            result.append(session.cwd)
            let comps = session.cwd.split(separator: "/").map(String.init)
            if comps.count >= 2 { result.append(comps.suffix(2).joined(separator: "/")) }
        }
        return dedupe(result)
    }

    /// Order-preserving de-duplication. Kept as an actor-isolated method so it
    /// doesn't inherit the project's default `@MainActor` isolation.
    private func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Strategy 2: Terminal.app / iTerm2 (AppleScript, exact TTY)

    private enum ScriptOutcome: Sendable {
        case focused
        case noMatch
        case noPermission
    }

    private func focusViaAppleScript(kind: TerminalKind, tty: String) async -> ScriptOutcome {
        let target = escapeAppleScript(tty)
        let script: String

        switch kind {
        case .terminalApp:
            script = """
            tell application "Terminal"
                set targetTTY to "\(target)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t) ends with targetTTY then
                                set selected of t to true
                                set frontmost of w to true
                                activate
                                return "focused"
                            end if
                        end try
                    end repeat
                end repeat
                return "no-match"
            end tell
            """
        case .iTerm2:
            script = """
            tell application "iTerm2"
                set targetTTY to "\(target)"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) ends with targetTTY then
                                    select s
                                    select t
                                    select w
                                    activate
                                    return "focused"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
                return "no-match"
            end tell
            """
        default:
            return .noMatch
        }

        return await executeAppleScript(script)
    }

    /// Execute in-process so the Automation (Apple events) prompt is attributed
    /// to Vibe Notch and picks up NSAppleEventsUsageDescription from our
    /// Info.plist. Spawning `osascript` would leave TCC attribution ambiguous.
    private func executeAppleScript(_ source: String) async -> ScriptOutcome {
        let outcome: ScriptOutcome = await MainActor.run {
            var errorInfo: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return .noMatch }
            let result = script.executeAndReturnError(&errorInfo)

            if let errorInfo {
                // -1743: not authorised to send Apple events.
                // -1744: a privilege violation (same class of problem).
                let code = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
                if code == -1743 || code == -1744 { return .noPermission }
                return .noMatch
            }
            return result.stringValue == "focused" ? .focused : .noMatch
        }
        return outcome
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Strategy 3: WezTerm (CLI, exact pane)

    private func focusViaWezTerm(
        session: SessionState,
        tty: String?,
        candidates: [String]
    ) async -> [String]? {
        guard let cli = wezTermCLIPath() else { return nil }

        let result = await ProcessExecutor.shared.runWithResult(
            cli, arguments: ["cli", "list", "--format", "json"]
        )
        guard case .success(let process) = result,
              let data = process.output.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var bestPaneId: Int?
        var bestTitles: [String] = []
        var bestScore = 0

        for pane in panes {
            var score = 0

            if let tty,
               let name = pane["tty_name"] as? String,
               normalizedTTY(name) == tty {
                score += 100
            }

            if !session.cwd.isEmpty,
               let rawCwd = pane["cwd"] as? String,
               wezTermCwdPath(rawCwd) == session.cwd {
                score += 50
            }

            let title = pane["title"] as? String ?? ""
            let windowTitle = pane["window_title"] as? String ?? ""
            if candidates.contains(where: { candidate in
                title.localizedCaseInsensitiveContains(candidate)
                    || windowTitle.localizedCaseInsensitiveContains(candidate)
            }) {
                score += 10
            }

            if score > bestScore, let paneId = pane["pane_id"] as? Int {
                bestScore = score
                bestPaneId = paneId
                bestTitles = [windowTitle, title].filter { !$0.isEmpty }
            }
        }

        guard let paneId = bestPaneId else { return nil }
        _ = await ProcessExecutor.shared.runWithResult(
            cli, arguments: ["cli", "activate-pane", "--pane-id", String(paneId)]
        )
        return bestTitles
    }

    private func wezTermCLIPath() -> String? {
        let paths = [
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// WezTerm reports cwd as `file://hostname/path`; only the path matters.
    private func wezTermCwdPath(_ raw: String) -> String {
        if let url = URL(string: raw), !url.path.isEmpty { return url.path }
        if let schemeRange = raw.range(of: "file://") {
            let rest = String(raw[schemeRange.upperBound...])
            if let slash = rest.firstIndex(of: "/") { return String(rest[slash...]) }
        }
        return raw
    }

    // MARK: - Strategy 4/5: activate app + raise best matching window

    /// Always activates the host app first. Without Accessibility (or without a
    /// title match) this is still a useful jump instead of a silent no-op.
    private func focusWithAccessibility(
        host: HostAppInfo,
        kind: TerminalKind,
        candidates: [String]
    ) async -> TerminalFocusResult {
        await activateApp(pid: host.pid)

        guard AXIsProcessTrusted() else {
            return .activated(terminal: kind.displayName, needsPermission: true)
        }

        let raised = raiseBestWindow(terminalPid: host.pid, candidates: candidates)
        return raised
            ? .focused(terminal: kind.displayName)
            : .activated(terminal: kind.displayName, needsPermission: false)
    }

    private func activateApp(pid: Int) async {
        _ = await MainActor.run {
            NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
        }
    }

    /// Returns true when a window was actually raised (exact or unambiguous).
    private func raiseBestWindow(terminalPid: Int, candidates: [String]) -> Bool {
        let windows = axWindows(for: pid_t(terminalPid))
        guard !windows.isEmpty else { return false }

        var bestIndex: Int?
        var bestScore = 0
        for (index, window) in windows.enumerated() {
            let title = axTitle(window)
            for candidate in candidates where !candidate.isEmpty {
                // Longer matches are more specific ("GitHub/vibe-notch" beats
                // "vibe-notch") and therefore win.
                if title.localizedCaseInsensitiveContains(candidate),
                   candidate.count > bestScore {
                    bestScore = candidate.count
                    bestIndex = index
                }
            }
        }

        // A single window is unambiguous even if its title doesn't match.
        if windows.count == 1 { bestIndex = 0 }
        guard let index = bestIndex else { return false }

        AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
        let appElement = AXUIElementCreateApplication(pid_t(terminalPid))
        _ = AXUIElementSetAttributeValue(
            appElement, kAXMainWindowAttribute as CFString, windows[index]
        )
        return true
    }

    private func axWindows(for pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private func axTitle(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else {
            return ""
        }
        return title
    }
}
