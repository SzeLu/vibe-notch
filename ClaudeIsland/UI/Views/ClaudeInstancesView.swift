//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.4))

            Text("Start a session in any supported agent")
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        let labels = folderLabels
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(sortedInstances) { session in
                    InstanceRow(
                        session: session,
                        folderLabel: labels[session.sessionId] ?? session.projectName,
                        onFocus: { focusSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onReject: { rejectSession(session) },
                        onShell: { viewModel.showShell(sessionId: session.sessionId) },
                        onMonitor: { viewModel.showMonitor(sessionId: session.sessionId) }
                    )
                    .id(session.stableId)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Disambiguated folder label per session. When two sessions share the same
    /// trailing folder name but live at different absolute paths, each label is
    /// expanded from the first differing path component down to the leaf, so
    /// `GitHub/vibe-notch` and `work/vibe-notch` stay distinguishable.
    private var folderLabels: [String: String] {
        var groups: [String: [SessionState]] = [:]
        for session in sortedInstances where !session.cwd.isEmpty {
            groups[session.projectName, default: []].append(session)
        }

        var labels: [String: String] = [:]
        for (name, group) in groups {
            if Set(group.map(\.cwd)).count <= 1 {
                for session in group { labels[session.sessionId] = name }
                continue
            }
            let cwds = group.map(\.cwd)
            for session in group {
                labels[session.sessionId] = Self.disambiguatedLabel(session.cwd, among: cwds)
            }
        }
        return labels
    }

    /// Minimal unique trailing path suffix for `cwd` relative to `cwds`,
    /// bounded in length so it never renders unreasonably long.
    private static func disambiguatedLabel(_ cwd: String, among cwds: [String]) -> String {
        let comps = cwd.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return cwd }
        let others = cwds.filter { $0 != cwd }.map { $0.split(separator: "/").map(String.init) }

        for n in 1...comps.count {
            let suffix = Array(comps.suffix(n))
            let label = suffix.joined(separator: "/")
            let shared = others.contains { other in
                other.count >= n && Array(other.suffix(n)) == suffix
            }
            if !shared || label.count > 40 { return label }
        }
        return comps.joined(separator: "/")
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        guard session.isInTmux else { return }

        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    /// Disambiguated folder label (may include extra path components when
    /// another session shares the same trailing folder name).
    let folderLabel: String
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onShell: () -> Void
    let onMonitor: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isYabaiAvailable = false
    @State private var gitRepo: GitInfo.Repo?

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Status text based on session phase (fallback when no other content)
    private var phaseStatusText: String {
        switch session.phase {
        case .processing:
            return "Processing..."
        case .compacting:
            return "Compacting..."
        case .waitingForInput:
            return "Ready"
        case .waitingForApproval:
            return "Waiting for approval"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Provider mark at the start of the row
            AgentIcon(kind: session.source, size: 16)

            // State indicator
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    // Token usage indicator
                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.3))
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.primary.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4))
                        .lineLimit(1)
                } else {
                    // Fallback: show phase-based status when no other content
                    Text(L(phaseStatusText))
                        .font(.system(size: 11))
                        .foregroundColor(.primary.opacity(0.4))
                        .lineLimit(1)
                }

                // Working directory + git branch for this session
                if !session.cwd.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundColor(.primary.opacity(0.3))

                        Text(folderLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        if let branch = gitRepo?.displayBranch, !branch.isEmpty {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(.primary.opacity(0.3))
                                .padding(.leading, 2)

                            Text(branch)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.45))
                                .lineLimit(1)
                                .layoutPriority(2)
                        }
                    }
                    .help(session.cwd)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Chat history is only available for Claude transcripts.
                    if session.source.supportsChatHistory {
                        IconButton(icon: "bubble.left") {
                            onChat()
                        }
                    }

                    // Shell commands this session has run
                    IconButton(icon: "terminal") {
                        onShell()
                    }

                    // Background tasks this session has spawned
                    IconButton(icon: "timer") {
                        onMonitor()
                    }

                    // Focus icon (only for tmux instances with yabai)
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }

                    // Archive button - only for idle or completed sessions of
                    // agents that support it. Polled sessions are re-discovered
                    // on the next tick, so archiving them would be undone.
                    if session.source.supportsArchive &&
                        (session.phase == .idle || session.phase == .waitingForInput) {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if session.source.supportsChatHistory {
                onChat()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
        .task(id: session.cwd) {
            guard !session.cwd.isEmpty else { return }
            let cwd = session.cwd
            gitRepo = await Task.detached(priority: .utility) {
                GitInfo.repo(for: cwd)
            }.value
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.primary.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.panel)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .primary.opacity(0.8) : .primary.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .primary.opacity(0.9) : .primary.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.primary.opacity(0.15) : Color.primary.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? Theme.panel : .primary.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.primary.opacity(0.95) : Color.primary.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
