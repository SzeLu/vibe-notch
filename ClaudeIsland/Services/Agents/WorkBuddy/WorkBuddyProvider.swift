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

final class WorkBuddyProvider: PollingAgentProvider {
    private static let heartbeatTTL: TimeInterval = 90

    init() {
        super.init(kind: .workBuddy)
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

            let heartbeat = date(fromMilliseconds: json["lastHeartbeat"]) ?? Date.distantPast
            let age = now.timeIntervalSince(heartbeat)
            guard age >= 0, age < Self.heartbeatTTL else { continue }

            // Heartbeat files can outlive their process after a crash.
            let pid = json["pid"] as? Int
            if let pid, !isProcessAlive(pid) { continue }

            let metadata = workbuddyMetadata(sessionId: rawId, home: home)
            let status = metadata?["status"] as? String ?? ""
            // An empty status means the DB read failed — keep the live heartbeat.
            guard status.isEmpty || status == "working" || status == "pending" else { continue }

            let transcript = modificationDate(
                of: rawId + ".jsonl",
                under: home + "/.workbuddy-ai/projects"
            )
            let lastActivity = date(fromMilliseconds: metadata?["last_activity_at"])
                ?? max(heartbeat, transcript ?? Date.distantPast)

            result.append(snapshot(
                rawId: rawId,
                cwd: json["cwd"] as? String ?? "",
                title: metadata?["title"] as? String,
                model: metadata?["model"] as? String,
                phase: phase(lastWrite: transcript, now: now),
                pid: pid,
                lastActivity: lastActivity
            ))
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
