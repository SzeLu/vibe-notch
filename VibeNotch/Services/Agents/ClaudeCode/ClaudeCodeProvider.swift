//
//  ClaudeCodeProvider.swift
//  VibeNotch
//
//  Claude Code integration: installs its hooks and drives state from the
//  unix-socket event stream. This is the only hook-driven provider; everything
//  it needs (installer, socket server, transcript parser) stays behind it.
//

import Foundation

final class ClaudeCodeProvider: AgentProvider, @unchecked Sendable {
    let kind: AgentKind = .claudeCode

    func start() {
        HookInstaller.installIfNeeded()

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stop() {
        HookSocketServer.shared.stop()
    }
}
