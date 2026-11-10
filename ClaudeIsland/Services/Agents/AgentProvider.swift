//
//  AgentProvider.swift
//  ClaudeIsland
//
//  The contract every agent integration implements, plus the uniform snapshot
//  that all of them publish into SessionStore.
//

import Foundation

/// A session as reported by any agent provider, independent of how it was
/// discovered (hooks, heartbeat files, SQLite databases, ...).
struct AgentSessionSnapshot: Sendable, Equatable {
    let kind: AgentKind
    /// Store key — already prefixed with the agent's namespace.
    let sessionId: String
    let cwd: String
    let title: String?
    let model: String?
    let phase: SessionPhase
    let pid: Int?
    let lastActivity: Date
}

/// One self-contained integration for a single coding agent.
///
/// Hook-driven providers (Claude Code) push `SessionEvent`s directly.
/// Polling providers publish `AgentSessionSnapshot`s through SessionStore.
/// Both only need `start()` / `stop()` from the outside.
protocol AgentProvider: AnyObject {
    var kind: AgentKind { get }
    func start()
    func stop()
}
