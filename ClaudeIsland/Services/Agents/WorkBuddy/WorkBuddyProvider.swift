//
//  WorkBuddyProvider.swift
//  ClaudeIsland
//
//  WorkBuddy integration. All heavy lifting (timer, read-only SQLite,
//  transcript mtime, phase mapping) comes from PollingAgentProvider.
//
//  Data sources:
//    ~/.workbuddy-ai/sessions/<pid>.json   live heartbeats
//    ~/.workbuddy-ai/workbuddy.db          title / status / model (read-only)
//    ~/.workbuddy-ai/projects/*/<id>.jsonl transcript write time
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "WorkBuddy")

final class WorkBuddyProvider: PollingAgentProvider {
    private static let heartbeatTTL: TimeInterval = 90
    /// A finished session keeps showing its "done" state for this long before
    /// it is dropped, so the user still sees the completed card if they come
    /// back shortly after a turn ends.
    private static let completedDisplayWindow: TimeInterval = 10 * 60

    /// Only log when the discovered set of sessions actually changes, so the
    /// 3s poll loop doesn't flood the unified log with repetitive entries.
    private var lastReportedSignature: String?

    init() {
        // WorkBuddy writes its transcript in bursts; give a turn a longer
        // quiet window before it can be considered finished. (Used only as a
        // fallback when the DB status is unavailable.)
        super.init(kind: .workBuddy, busyWindow: 90)
    }

    override func discover() -> [AgentSessionSnapshot] {
        let home = NSHomeDirectory()
        let sessionsDir = home + "/.workbuddy-ai/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }

        let now = Date()
        var result: [AgentSessionSnapshot] = []

        for name in files where name.hasSuffix(".json") {
            let path = sessionsDir + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawId = json["sessionId"] as? String,
                  !rawId.isEmpty else { continue }

            // WorkBuddy keeps a pool of prewarmed agent processes alive; their
            // heartbeats are not real user sessions and would otherwise surface
            // as a phantom "/" session in the notch. Skip them.
            guard (json["kind"] as? String) != "prewarm" else { continue }

            let heartbeat = date(fromMilliseconds: json["lastHeartbeat"]) ?? Date.distantPast
            let age = now.timeIntervalSince(heartbeat)
            guard age >= 0, age < Self.heartbeatTTL else { continue }

            // Heartbeat files can outlive their process after a crash.
            let pid = json["pid"] as? Int
            if let pid, !isProcessAlive(pid) { continue }

            let metadata = workbuddyMetadata(sessionId: rawId, home: home)
            let status = (metadata?["status"] as? String ?? "").lowercased()

            let transcript = modificationDate(
                of: rawId + ".jsonl",
                under: home + "/.workbuddy-ai/projects"
            )
            let lastActivity = date(fromMilliseconds: metadata?["last_activity_at"])
                ?? max(heartbeat, transcript ?? Date.distantPast)

            // WorkBuddy records an explicit per-session status. That is a far
            // more reliable "is this turn still running?" signal than transcript
            // mtimes: mtimes go quiet between tool calls, which used to make a
            // single turn announce "done" several times. With the status field
            // one turn yields exactly one working → completed transition.
            let resolvedPhase: SessionPhase
            switch status {
            case "working", "pending", "running", "busy":
                resolvedPhase = .processing
            case "completed", "complete", "done", "error", "idle":
                // Drop finished sessions after the display window so old cards
                // don't pile up while WorkBuddy keeps the process alive.
                if now.timeIntervalSince(lastActivity) > Self.completedDisplayWindow {
                    continue
                }
                resolvedPhase = .waitingForInput
            default:
                // Empty / unknown status (e.g. DB read failed) — fall back to
                // the transcript write time.
                resolvedPhase = phase(lastWrite: transcript, now: now)
            }

            result.append(snapshot(
                rawId: rawId,
                cwd: json["cwd"] as? String ?? "",
                title: metadata?["title"] as? String,
                model: metadata?["model"] as? String,
                phase: resolvedPhase,
                pid: pid,
                lastActivity: lastActivity
            ))
        }

        // Diagnostics: only emit when the discovered set changes.
        let signature = result
            .map { "\($0.sessionId):\($0.phase)" }
            .sorted()
            .joined(separator: ", ")
        if signature != lastReportedSignature {
            lastReportedSignature = signature
            if signature.isEmpty {
                logger.info("WorkBuddy: no live sessions discovered")
            } else {
                logger.info("WorkBuddy: discovered \(result.count) session(s): \(signature, privacy: .public)")
            }
        }

        return result
    }

    private func workbuddyMetadata(sessionId: String, home: String) -> [String: Any]? {
        let dbPath = home + "/.workbuddy-ai/workbuddy.db"
        let escaped = sessionId.replacingOccurrences(of: "'", with: "''")
        let sql = "select case when length(coalesce(custom_title,'')) > 0 then custom_title else title end as title, status, model, last_activity_at from sessions where id = '\(escaped)' limit 1;"
        return sqliteRows(dbPath: dbPath, sql: sql).first
    }
}
