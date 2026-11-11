//
//  AgentKind.swift
//  VibeNotch
//
//  Every supported coding agent is an independent provider unit. Capabilities
//  are declared here so SessionStore and the UI never need agent-specific
//  conditionals scattered around the codebase.
//

import Foundation

enum AgentKind: String, Sendable, CaseIterable {
    case claudeCode
    case workBuddy
    case openCode
    case lmStudio

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .workBuddy: return "WorkBuddy"
        case .openCode: return "OpenCode"
        case .lmStudio: return "LM Studio"
        }
    }

    /// Short marker shown in a session row. Claude Code is the default, so it
    /// stays unlabelled to keep the original UI unchanged.
    var badge: String {
        switch self {
        case .claudeCode: return ""
        case .workBuddy: return "WB"
        case .openCode: return "OC"
        case .lmStudio: return "LM"
        }
    }

    /// Prefix for the SessionStore key, so ids from different agents never
    /// collide even if two tools happen to generate the same uuid.
    var sessionKeyPrefix: String {
        switch self {
        case .claudeCode: return ""   // hook events already use globally unique ids
        case .workBuddy: return "wb-"
        case .openCode: return "oc-"
        case .lmStudio: return "lms-"
        }
    }

    /// Only Claude Code writes the Claude JSONL transcript format.
    var usesClaudeTranscript: Bool { self == .claudeCode }

    /// Chat history / interrupt watching only work with Claude transcripts.
    var supportsChatHistory: Bool { usesClaudeTranscript }

    /// Polled sessions are re-discovered on the next tick, so archiving them
    /// would be undone immediately.
    var supportsArchive: Bool { self == .claudeCode }
}
