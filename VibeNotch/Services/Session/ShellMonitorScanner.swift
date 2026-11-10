//
//  ShellMonitorScanner.swift
//  VibeNotch
//
//  Extracts shell commands and background tasks from an agent transcript.
//
//  Supported shapes (all verified against real local data):
//   • Claude Code  : message.content[] { tool_use / tool_result }
//   • WorkBuddy    : top-level { type: function_call / function_call_result }
//   • OpenCode     : content[] { type: tool, name, state.input.command, state.content }
//   • Generic      : any JSON object with a shell-ish "name"/"tool" + a command field
//
//  Pure and side-effect free: it returns records; SessionStore merges/notifies.
//

import Foundation

struct ShellMonitorScanResult: Sendable {
    var shellCommands: [ShellCommandRecord] = []
    var backgroundTasks: [BackgroundTaskRecord] = []
}

enum ShellMonitorScanner {
    /// Lowercased tool names that represent running a shell command.
    static let shellToolNames: Set<String> = [
        "bash", "powershell", "shell", "sh", "zsh", "run_command", "runcommand",
        "execute", "exec", "terminal", "command", "run_shell_command", "shell_command",
    ]

    static func isShellTool(_ name: String) -> Bool {
        shellToolNames.contains(name.lowercased())
    }

    // MARK: - Internal models

    private struct ToolUseInfo {
        let name: String
        let command: String
        let runInBackground: Bool
        let startedAt: Date
    }

    private struct ToolResultInfo {
        let isError: Bool
        let isInterrupted: Bool
        let stdout: String?
        let backgroundTaskId: String?
        let finishedAt: Date
    }

    // MARK: - Public entry points

    static func scan(data: Data, sessionId: String, agentKind: AgentKind) -> ShellMonitorScanResult {
        let text = String(data: data, encoding: .utf8) ?? ""
        return scan(text: text, sessionId: sessionId, agentKind: agentKind)
    }

    static func scan(text: String, sessionId: String, agentKind: AgentKind) -> ShellMonitorScanResult {
        var toolUses: [String: ToolUseInfo] = [:]
        var order: [String] = []
        var toolResults: [String: ToolResultInfo] = [:]
        var completedTasks: [String: BackgroundTaskStatus] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)

            if line.contains("task-notification") || line.contains("<task-id>") {
                extractTaskNotifications(from: line, into: &completedTasks)
            }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let timestamp = parseTimestamp(json) ?? Date()
            let type = json["type"] as? String

            if type == "function_call" {
                // WorkBuddy tool invocation
                ingestWorkBuddyCall(json, ts: timestamp, toolUses: &toolUses, order: &order)
                continue
            }
            if type == "function_call_result" {
                // WorkBuddy tool result
                ingestWorkBuddyResult(json, ts: timestamp, toolResults: &toolResults)
                continue
            }

            // Claude Code (message.content[]) and OpenCode (top-level content[])
            var handledBlock = false
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    ingestBlock(block, json: json, ts: timestamp,
                                toolUses: &toolUses, order: &order, toolResults: &toolResults)
                    handledBlock = true
                }
            }
            if let content = json["content"] as? [[String: Any]] {
                for block in content {
                    ingestBlock(block, json: json, ts: timestamp,
                                toolUses: &toolUses, order: &order, toolResults: &toolResults)
                    handledBlock = true
                }
            }

            if !handledBlock, let parsed = parseGenericToolUse(json, ts: timestamp) {
                if toolUses[parsed.id] == nil { order.append(parsed.id) }
                toolUses[parsed.id] = parsed.info
            }
        }

        return buildResult(order: order, toolUses: toolUses, toolResults: toolResults,
                           completedTasks: completedTasks, sessionId: sessionId, agentKind: agentKind)
    }

    // MARK: - Block ingestion (Claude / OpenCode)

    private static func ingestBlock(
        _ block: [String: Any],
        json: [String: Any],
        ts: Date,
        toolUses: inout [String: ToolUseInfo],
        order: inout [String],
        toolResults: inout [String: ToolResultInfo]
    ) {
        switch block["type"] as? String {
        case "tool_use": // Claude Code
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
            let input = block["input"] as? [String: Any]
            let command = firstString(in: input, keys: ["command", "cmd", "script"]) ?? ""
            let runInBackground = (input?["run_in_background"] as? Bool) ?? false
            if toolUses[id] == nil { order.append(id) }
            toolUses[id] = ToolUseInfo(name: name, command: command,
                                       runInBackground: runInBackground, startedAt: ts)

        case "tool_result": // Claude Code
            guard let toolUseId = block["tool_use_id"] as? String else { return }
            let toolUseResult = json["toolUseResult"] as? [String: Any]
            let isError = (block["is_error"] as? Bool) ?? false
            let isInterrupted = (toolUseResult?["interrupted"] as? Bool) ?? false
            var stdout = toolUseResult?["stdout"] as? String
            if stdout == nil { stdout = extractText(block["content"]) }
            toolResults[toolUseId] = ToolResultInfo(
                isError: isError, isInterrupted: isInterrupted,
                stdout: stdout,
                backgroundTaskId: toolUseResult?["backgroundTaskId"] as? String,
                finishedAt: ts
            )

        case "tool": // OpenCode
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return }
            let state = block["state"] as? [String: Any]
            let input = state?["input"] as? [String: Any]
            let command = firstString(in: input, keys: ["command", "cmd", "script"]) ?? ""
            let runInBackground = (input?["run_in_background"] as? Bool) ?? false
            if toolUses[id] == nil { order.append(id) }
            toolUses[id] = ToolUseInfo(name: name, command: command,
                                       runInBackground: runInBackground, startedAt: ts)

            if let status = (state?["status"] as? String)?.lowercased(), isTerminalStatus(status) {
                toolResults[id] = ToolResultInfo(
                    isError: status.contains("error") || status.contains("fail"),
                    isInterrupted: status.contains("abort") || status.contains("cancel"),
                    stdout: extractText(state?["content"]),
                    backgroundTaskId: nil,
                    finishedAt: ts
                )
            }

        default:
            break
        }
    }

    // MARK: - WorkBuddy ingestion

    private static func ingestWorkBuddyCall(
        _ json: [String: Any],
        ts: Date,
        toolUses: inout [String: ToolUseInfo],
        order: inout [String]
    ) {
        guard let name = json["name"] as? String, isShellTool(name) else { return }
        let id = (json["callId"] as? String) ?? (json["id"] as? String) ?? ""
        guard !id.isEmpty else { return }

        // `arguments` is a JSON-encoded string in WorkBuddy transcripts.
        let args = decodeArguments(json["arguments"])
        let command = firstString(in: args, keys: ["command", "cmd", "script"]) ?? ""
        guard !command.isEmpty else { return }
        let runInBackground = (args?["run_in_background"] as? Bool) ?? false

        if toolUses[id] == nil { order.append(id) }
        toolUses[id] = ToolUseInfo(name: name, command: command,
                                   runInBackground: runInBackground, startedAt: ts)
    }

    private static func ingestWorkBuddyResult(
        _ json: [String: Any],
        ts: Date,
        toolResults: inout [String: ToolResultInfo]
    ) {
        guard let callId = json["callId"] as? String else { return }
        let status = (json["status"] as? String)?.lowercased() ?? ""
        var output: String?
        if let dict = json["output"] as? [String: Any] {
            output = dict["text"] as? String
        } else if let str = json["output"] as? String {
            output = str
        }
        toolResults[callId] = ToolResultInfo(
            isError: status.contains("error") || status.contains("fail"),
            isInterrupted: status.contains("abort") || status.contains("cancel"),
            stdout: output, backgroundTaskId: nil, finishedAt: ts
        )
    }

    // MARK: - Result building

    private static func buildResult(
        order: [String],
        toolUses: [String: ToolUseInfo],
        toolResults: [String: ToolResultInfo],
        completedTasks: [String: BackgroundTaskStatus],
        sessionId: String,
        agentKind: AgentKind
    ) -> ShellMonitorScanResult {
        var result = ShellMonitorScanResult()

        for id in order {
            guard let use = toolUses[id], isShellTool(use.name) else { continue }
            let res = toolResults[id]

            let status: CommandStatus
            if let res {
                status = res.isInterrupted ? .interrupted : (res.isError ? .error : .success)
            } else {
                status = .running
            }

            result.shellCommands.append(ShellCommandRecord(
                id: id,
                sessionId: sessionId,
                agentKind: agentKind,
                command: use.command.isEmpty ? "(\(use.name))" : use.command,
                toolName: use.name,
                startedAt: use.startedAt,
                finishedAt: res?.finishedAt,
                status: status,
                exitCode: nil,
                output: res?.stdout.map { truncate($0) }
            ))

            if use.runInBackground {
                let bgId = res?.backgroundTaskId ?? id
                var bgStatus: BackgroundTaskStatus = .running
                if let completed = completedTasks[bgId] ?? completedTasks[id] {
                    bgStatus = completed
                }
                result.backgroundTasks.append(BackgroundTaskRecord(
                    id: bgId,
                    sessionId: sessionId,
                    agentKind: agentKind,
                    label: use.command,
                    startedAt: use.startedAt,
                    finishedAt: bgStatus == .running ? nil : Date(),
                    status: bgStatus,
                    notified: false,
                    output: nil
                ))
            }
        }

        return result
    }

    // MARK: - Generic fallback

    private static func parseGenericToolUse(
        _ json: [String: Any],
        ts: Date
    ) -> (id: String, info: ToolUseInfo)? {
        let name = (json["tool"] as? String) ?? (json["name"] as? String) ?? (json["tool_name"] as? String)
        guard let name, isShellTool(name) else { return nil }

        let input = decodeArguments(json["arguments"])
            ?? (json["input"] as? [String: Any])
            ?? (json["params"] as? [String: Any])
        let command = firstString(in: input, keys: ["command", "cmd", "script"]) ?? ""
        guard !command.isEmpty else { return nil }

        let id = (json["id"] as? String)
            ?? (json["tool_call_id"] as? String)
            ?? (json["call_id"] as? String)
            ?? "shell-\(StableHash.hash(command.prefix(80)))"

        return (id, ToolUseInfo(
            name: name, command: command,
            runInBackground: (input?["run_in_background"] as? Bool) ?? false,
            startedAt: ts
        ))
    }

    // MARK: - Helpers

    private static func decodeArguments(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let str = raw as? String, let data = str.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    private static func firstString(in dict: [String: Any]?, keys: [String]) -> String? {
        guard let dict else { return nil }
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Flatten a content value that may be a String or an array of text blocks.
    private static func extractText(_ raw: Any?) -> String? {
        if let str = raw as? String { return str.isEmpty ? nil : str }
        if let blocks = raw as? [[String: Any]] {
            let parts = blocks.compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    private static func isTerminalStatus(_ status: String) -> Bool {
        if status.contains("running") || status.contains("pending") || status.contains("progress") {
            return false
        }
        return true
    }

    private static func extractTaskNotifications(from line: String, into dict: inout [String: BackgroundTaskStatus]) {
        guard let taskId = firstMatch(line, pattern: "<task-id>([^<]+)</task-id>") else { return }
        let statusRaw = (firstMatch(line, pattern: "<status>([^<]+)</status>") ?? "").lowercased()
        let status: BackgroundTaskStatus =
            (statusRaw.contains("error") || statusRaw.contains("fail") || statusRaw.contains("cancel"))
            ? .error : .success
        dict[taskId] = status
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func truncate(_ s: String, limit: Int = 4000) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    private static func parseTimestamp(_ json: [String: Any]) -> Date? {
        if let d = parseDate(json["timestamp"]) { return d }
        if let time = json["time"] as? [String: Any], let d = parseDate(time["created"]) { return d }
        return nil
    }

    // MARK: - Date parsing

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ value: Any?) -> Date? {
        if let str = value as? String {
            return isoWithFraction.date(from: str) ?? isoBasic.date(from: str)
        }
        if let num = value as? NSNumber {
            let ms = num.doubleValue
            return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        }
        return nil
    }
}
