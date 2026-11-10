//
//  AgentRegistry.swift
//  ClaudeIsland
//
//  Single lifecycle entry point for all agent integrations.
//  Adding a new agent = one provider file + one line in `buildProviders()`.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "Agents")

@MainActor
final class AgentRegistry {
    static let shared = AgentRegistry()

    private var providers: [any AgentProvider] = []
    private var isStarted = false

    private init() {
        providers = Self.buildProviders()
    }

    func startAll() {
        guard !isStarted else { return }
        isStarted = true
        for provider in providers {
            logger.info("Starting \(provider.kind.displayName, privacy: .public) provider")
            provider.start()
        }
    }

    func stopAll() {
        guard isStarted else { return }
        isStarted = false
        for provider in providers {
            provider.stop()
        }
    }

    private static func buildProviders() -> [any AgentProvider] {
        [
            ClaudeCodeProvider(),  // hook / unix-socket driven
            WorkBuddyProvider(),   // heartbeat + read-only SQLite + transcript mtime
            OpenCodeProvider(),    // read-only SQLite session store
        ]
    }
}
