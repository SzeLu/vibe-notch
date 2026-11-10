//
//  ShellMonitorModels.swift
//  VibeNotch
//
//  Data models for the Shell and Monitor features.
//
//  ShellCommandRecord  -> a shell command an agent executed (Bash / PowerShell / ...).
//  BackgroundTaskRecord -> a long-running ("detached") task an agent spawned and
//                          whose completion we surface in the notch.
//
//  Both are agent-agnostic: any AgentProvider can emit them through SessionStore,
//  so the Shell / Monitor panels work for every supported coding agent.
//

import Foundation

extension Notification.Name {
    /// Posted when an agent's background task finishes. The notch observes this
    /// to bounce + play a completion sound, mirroring the turn-completion UX.
    static let claudeIslandBackgroundTaskCompleted = Notification.Name("claudeIsland.backgroundTaskCompleted")
}

/// Lifecycle status of a shell command an agent ran.
enum CommandStatus: String, Equatable, Sendable, Codable {
    case running
    case success
    case error
    case interrupted
}

/// Lifecycle status of a background / detached task.
enum BackgroundTaskStatus: String, Equatable, Sendable, Codable {
    case running
    case success
    case error
}

/// One shell command executed by an agent.
/// `id` is the stable tool_use_id (or an equivalent per-agent key) so the same
/// command is upserted, never duplicated, as status updates arrive.
struct ShellCommandRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let agentKind: AgentKind
    let command: String
    let toolName: String
    let startedAt: Date
    var finishedAt: Date?
    var status: CommandStatus
    var exitCode: Int?
    /// Truncated output for preview (stdout / stderr).
    var output: String?

    var isActive: Bool { status == .running }

    /// Short single-line preview of the command for list rows.
    var commandPreview: String {
        let firstLine = command.components(separatedBy: "\n").first ?? command
        return firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine
    }
}

/// One background / detached task spawned by an agent.
/// Completion is reported to the UI (bounce + sound) exactly once.
struct BackgroundTaskRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sessionId: String
    let agentKind: AgentKind
    /// Human-readable label — usually the command or a description.
    let label: String
    let startedAt: Date
    var finishedAt: Date?
    var status: BackgroundTaskStatus
    /// Whether the completion notification has already been delivered.
    var notified: Bool
    var output: String?

    var isActive: Bool { status == .running }
}
