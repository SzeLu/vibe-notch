//
//  PollingAgentProvider.swift
//  VibeNotch
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

    /// Number of consecutive idle polls before "done" is published.
    /// Polled transcripts are bursty — a single turn can be quiet for a long
    /// time between tool calls. Without this, the notch announces completion
    /// several times within one turn.
    private let phaseConfirmationTicks = 3

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var publishedPhases: [String: SessionPhase] = [:]
    private var idleTicks: [String: Int] = [:]

    init(kind: AgentKind, pollInterval: TimeInterval = 3, busyWindow: TimeInterval = 60) {
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
            self?.publishedPhases.removeAll()
            self?.idleTicks.removeAll()
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
        let stable = stabilize(discover())
        let agentKind = kind
        let targets = shellMonitorTargets()
        let blobs = shellMonitorBlobs()
        Task {
            await SessionStore.shared.applyAgentSnapshots(stable, from: agentKind)
            if !targets.isEmpty {
                await SessionStore.shared.scanShellMonitor(targets: targets)
            }
            if !blobs.isEmpty {
                await SessionStore.shared.scanShellMonitor(blobs: blobs)
            }
        }
    }

    /// Override in a provider to point at transcript files that should be
    /// scanned for shell commands / background tasks. Best-effort: if the
    /// agent's transcript format is not recognised, the scan simply yields
    /// nothing and the rest of the app is unaffected.
    func shellMonitorTargets() -> [(sessionId: String, fileURL: URL)] { [] }

    /// Override in a provider whose transcript lives in a database (OpenCode):
    /// return already-decoded JSONL-style blobs per session.
    func shellMonitorBlobs() -> [(sessionId: String, data: Data)] { [] }

    /// Debounce the busy/idle signal.
    ///
    /// A fresh write is published immediately (the agent is clearly working),
    /// but "waiting for input" is only announced after several consecutive
    /// idle polls. That keeps one turn from producing several completion
    /// notifications while still letting a real new turn show up at once.
    private func stabilize(_ snapshots: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        var result: [AgentSessionSnapshot] = []
        var seen: Set<String> = []

        for var snapshot in snapshots {
            seen.insert(snapshot.sessionId)
            let published = publishedPhases[snapshot.sessionId]

            switch snapshot.phase {
            case .processing:
                idleTicks.removeValue(forKey: snapshot.sessionId)
                publishedPhases[snapshot.sessionId] = .processing
                result.append(snapshot)

            case .waitingForInput:
                guard let published else {
                    // First sighting of this session — publish as discovered.
                    publishedPhases[snapshot.sessionId] = .waitingForInput
                    result.append(snapshot)
                    continue
                }

                if published == .waitingForInput {
                    idleTicks.removeValue(forKey: snapshot.sessionId)
                    result.append(snapshot)
                    continue
                }

                let ticks = (idleTicks[snapshot.sessionId] ?? 0) + 1
                if ticks >= phaseConfirmationTicks {
                    idleTicks.removeValue(forKey: snapshot.sessionId)
                    publishedPhases[snapshot.sessionId] = .waitingForInput
                    result.append(snapshot)
                } else {
                    // Hold the previous phase until the idle signal is stable.
                    idleTicks[snapshot.sessionId] = ticks
                    snapshot.phase = published
                    result.append(snapshot)
                }

            default:
                idleTicks.removeValue(forKey: snapshot.sessionId)
                publishedPhases[snapshot.sessionId] = snapshot.phase
                result.append(snapshot)
            }
        }

        for id in Set(publishedPhases.keys).subtracting(seen) {
            publishedPhases.removeValue(forKey: id)
            idleTicks.removeValue(forKey: id)
        }
        return result
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

    /// Resolve a transcript file URL by name under `<root>/<subdir>/<name>`.
    func fileURL(named filename: String, under root: String) -> URL? {
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for dir in dirs {
            let path = root + "/" + dir + "/" + filename
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
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
