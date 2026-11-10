//
//  OpenCodeProvider.swift
//  ClaudeIsland
//
//  OpenCode integration. Polling, read-only SQLite and phase mapping all come
//  from PollingAgentProvider — this file only knows OpenCode's schema.
//
//  Data source: ~/.local/share/opencode/opencode.db
//    session_v2      id / title / directory / model / time_updated
//    session_message last message write time per session
//

import Foundation

final class OpenCodeProvider: PollingAgentProvider {
    /// A session disappears from the notch after this long without any write.
    private static let activeWindow: TimeInterval = 30 * 60

    init() {
        super.init(kind: .openCode)
    }

    override func discover() -> [AgentSessionSnapshot] {
        let dbPath = Self.databasePath()
        let sql = """
        select s.id, s.title, s.directory, s.model, s.time_updated,
               coalesce((select max(m.time_updated) from session_message m
                         where m.session_id = s.id), s.time_updated) as last_write
        from session_v2 s
        order by last_write desc
        limit 25;
        """

        let rows = sqliteRows(dbPath: dbPath, sql: sql)
        guard !rows.isEmpty else { return [] }

        let now = Date()
        var result: [AgentSessionSnapshot] = []

        for row in rows {
            guard let rawId = row["id"] as? String, !rawId.isEmpty else { continue }
            let lastWrite = date(fromMilliseconds: row["last_write"])
                ?? date(fromMilliseconds: row["time_updated"])
            guard let lastWrite,
                  now.timeIntervalSince(lastWrite) < Self.activeWindow else { continue }

            result.append(snapshot(
                rawId: rawId,
                cwd: row["directory"] as? String ?? "",
                title: row["title"] as? String,
                model: Self.modelName(from: row["model"]),
                phase: phase(lastWrite: lastWrite, now: now),
                pid: nil,
                lastActivity: lastWrite
            ))
        }
        return result
    }

    private static func databasePath() -> String {
        if let override = Foundation.ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"],
           !override.isEmpty {
            return (override as NSString).appendingPathComponent("opencode.db")
        }
        return NSHomeDirectory() + "/.local/share/opencode/opencode.db"
    }

    /// `model` is a JSON blob like {"id":"...","providerID":"..."}.
    private static func modelName(from raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            return text
        }
        return id
    }
}
