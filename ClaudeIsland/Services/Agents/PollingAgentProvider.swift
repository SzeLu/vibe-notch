//
//  PollingAgentProvider.swift
//  ClaudeIsland
//
//  Shared machinery for agents that are discovered by polling local on-disk
//  state (WorkBuddy, OpenCode, ...). Subclasses implement only discover();
//  timers, read-only SQLite access, transcript mtimes and phase mapping live
//  here so adding another agent is a single small file.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "AgentPoll")

class PollingAgentProvider: AgentProvider, @unchecked Sendable {
    let kind: AgentKind
    let pollInterval: TimeInterval
    let busyWindow: TimeInterval

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(kind: AgentKind, pollInterval: TimeInterval = 3, busyWindow: TimeInterval = 30) {
        self.kind = kind
        self.pollInterval = pollInterval
        self.busyWindow = busyWindow
        self.queue = DispatchQueue(label: "com.claudeisland.agent.\(kind.rawValue)", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func startLocked() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.refresh() }
        source.resume()
        timer = source
        refresh()
    }

    private func refresh() {
        let found = discover()
        let agentKind = kind
        Task {
            await SessionStore.shared.applyAgentSnapshots(found, from: agentKind)
        }
    }

    /// Override in each provider. Always called on the provider's serial queue.
    func discover() -> [AgentSessionSnapshot] { [] }

    // MARK: - Shared low-level helpers

    /// Read-only SQLite query using the system `sqlite3` binary.
    /// Never opens the agent's database for writing.
    func sqliteRows(dbPath: String, sql: String) -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: dbPath),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", dbPath, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows
    }

    /// Find a file by name without assuming how the agent encodes project dirs.
    func modificationDate(of filename: String, under root: String) -> Date? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for dir in dirs {
            let path = root + "/" + dir + "/" + filename
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let date = attrs[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }

    func isProcessAlive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }

    /// Busy while the transcript / message stream was written recently.
    func phase(lastWrite: Date?, now: Date = Date()) -> SessionPhase {
        guard let lastWrite, now.timeIntervalSince(lastWrite) < busyWindow else {
            return .waitingForInput
        }
        return .processing
    }

    func date(fromMilliseconds value: Any?) -> Date? {
        guard let ms = value as? Double else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    /// Build a snapshot with the agent's key prefix applied.
    func snapshot(
        rawId: String,
        cwd: String,
        title: String?,
        model: String?,
        phase: SessionPhase,
        pid: Int?,
        lastActivity: Date
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            kind: kind,
            sessionId: kind.sessionKeyPrefix + rawId,
            cwd: cwd,
            title: title,
            model: model,
            phase: phase,
            pid: pid,
            lastActivity: lastActivity
        )
    }
}
