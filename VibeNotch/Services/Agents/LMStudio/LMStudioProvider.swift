//
//  LMStudioProvider.swift
//  VibeNotch
//
//  LM Studio integration. Watches every request that reaches the local LM
//  Studio API server (default 127.0.0.1:1234) by tailing the official
//  `lms log stream --json` CLI. No API token, no proxy, and no changes to
//  LM Studio's server settings are required — the CLI authenticates over its
//  own internal channel.
//
//  Two streams are tailed:
//    server : `server.log` rows carrying "METHOD /path" for HTTP requests
//    model  : `llm.prediction.input` / `.output` for generation start/end
//
//  Privacy: only event types, timestamps, model identifiers and the request
//  method/path are read. Prompt / response bodies (`input`, `output`) and raw
//  server log text are never retained and never written to os_log.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "LMStudio")

// MARK: - Thread-safe event state

private struct LMStudioActivity: Sendable {
    var lastEventAt: Date = .distantPast
    var lastRequestAt: Date?
    var lastRequestLine: String?
    var requestCount: Int = 0
    var predictionStartedAt: Date?
    var isPredicting = false
    var model: String?
}

/// Holds the most recent LM Studio activity. Written from the log tailer's
/// reader queues, read from PollingAgentProvider's serial poll queue.
private final class LMStudioEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: LMStudioActivity?

    func recordRequest(_ line: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var current = activity ?? LMStudioActivity()
        current.lastEventAt = max(current.lastEventAt, date)
        current.lastRequestAt = date
        current.lastRequestLine = line
        current.requestCount += 1
        activity = current
    }

    func recordPredictionStart(model: String?, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var current = activity ?? LMStudioActivity()
        current.lastEventAt = max(current.lastEventAt, date)
        current.predictionStartedAt = date
        current.isPredicting = true
        if let model, !model.isEmpty { current.model = model }
        activity = current
    }

    func recordPredictionEnd(model: String?, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        var current = activity ?? LMStudioActivity()
        current.lastEventAt = max(current.lastEventAt, date)
        current.isPredicting = false
        current.predictionStartedAt = nil
        if let model, !model.isEmpty { current.model = model }
        activity = current
    }

    func snapshot() -> LMStudioActivity? {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        activity = nil
    }
}

// MARK: - Log stream tailer

/// Runs `lms log stream --json` (model events) and
/// `lms log stream --json --source server` (HTTP request rows) as two long-lived
/// child processes, parses newline-delimited JSON, and feeds the event state.
/// If LM Studio is not running the CLI exits; we back off and retry.
private final class LMStudioLogTailer: @unchecked Sendable {
    private struct Stream {
        let process: Process
        let source: String
    }

    private static let sources = ["model", "server"]

    /// Matches "(POST /v1/chat/completions)" and plain "GET /v1/models" rows.
    private static let requestPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(/[^\s)\]]+)"#
    )

    private let executablePath: String
    private let state: LMStudioEventState
    private let queue = DispatchQueue(label: "com.claudeisland.lmstudio.tail", qos: .utility)
    private let lock = NSLock()

    private var streams: [Stream] = []
    private var buffers: [String: String] = [:]
    private var stopped = true
    private var restartScheduled = false
    private var retryDelay: TimeInterval = 2

    init(executablePath: String, state: LMStudioEventState) {
        self.executablePath = executablePath
        self.state = state
    }

    func start() {
        lock.lock()
        if !stopped { lock.unlock(); return }
        stopped = false
        retryDelay = 2
        lock.unlock()
        launchStreams()
    }

    func stop() {
        lock.lock()
        stopped = true
        restartScheduled = false
        let existing = streams
        streams.removeAll()
        buffers.removeAll()
        lock.unlock()

        for stream in existing { detach(stream) }
    }

    private func detach(_ stream: Stream) {
        stream.process.terminationHandler = nil
        (stream.process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if stream.process.isRunning { stream.process.terminate() }
    }

    private func launchStreams() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let existing = streams
        streams.removeAll()
        buffers.removeAll()
        restartScheduled = false
        lock.unlock()

        for stream in existing { detach(stream) }

        for source in Self.sources {
            guard let process = makeProcess(source: source) else { continue }
            lock.lock()
            if stopped {
                lock.unlock()
                process.terminationHandler = nil
                (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                return
            }
            streams.append(Stream(process: process, source: source))
            lock.unlock()
        }

        // A stream that failed to launch has no termination handler to wake us
        // up again, so retry whenever we ended up with fewer than both streams.
        lock.lock()
        let complete = streams.count == Self.sources.count
        lock.unlock()
        if !complete { scheduleRestart() }
    }

    private func makeProcess(source: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = ["log", "stream", "--json"]
        if source == "server" { arguments += ["--source", "server"] }
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data, source: source)
        }
        process.terminationHandler = { [weak self] terminated in
            self?.handleTermination(terminated)
        }

        do {
            try process.run()
        } catch {
            logger.warning("Could not start `lms log stream` (\(source, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            handle.readabilityHandler = nil
            process.terminationHandler = nil
            return nil
        }
        return process
    }

    private func handleTermination(_ process: Process) {
        lock.lock()
        streams.removeAll { $0.process === process }
        lock.unlock()
        scheduleRestart()
    }

    private func scheduleRestart() {
        lock.lock()
        guard !stopped, !restartScheduled else { lock.unlock(); return }
        restartScheduled = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        lock.unlock()

        logger.info("LM Studio log stream unavailable; reconnecting in \(delay, privacy: .public)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchStreams()
        }
    }

    private func consume(_ data: Data, source: String) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }

        lock.lock()
        let pending = (buffers[source] ?? "") + chunk
        var lines = pending.components(separatedBy: "\n")
        buffers[source] = lines.popLast()
        // Bound the buffer so a stream without newlines cannot grow forever.
        if let tail = buffers[source], tail.utf8.count > 64_000 { buffers[source] = "" }
        lock.unlock()

        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if handleLine(line, source: source) {
                lock.lock()
                retryDelay = 2
                lock.unlock()
            }
        }
    }

    /// Returns true when the line was a recognised JSON event.
    private func handleLine(_ line: String, source: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = envelope["data"] as? [String: Any],
              let type = payload["type"] as? String else { return false }

        let timestamp = (envelope["timestamp"] as? Double)
            .map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? Date()

        switch type {
        case "llm.prediction.input":
            // Deliberately never read payload["input"] — it contains the full prompt.
            state.recordPredictionStart(
                model: payload["modelIdentifier"] as? String,
                at: timestamp
            )
            return true

        case "llm.prediction.output":
            // Deliberately never read payload["output"] — it contains the full reply.
            state.recordPredictionEnd(
                model: payload["modelIdentifier"] as? String,
                at: timestamp
            )
            return true

        case "server.log":
            // Only the method + path are extracted; the raw log text is discarded.
            guard let content = payload["content"] as? String,
                  let request = Self.extractRequest(from: content) else { return false }
            state.recordRequest(request, at: timestamp)
            return true

        default:
            return false
        }
    }

    private static func extractRequest(from content: String) -> String? {
        guard let pattern = requestPattern else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = pattern.firstMatch(in: content, range: range),
              let methodRange = Range(match.range(at: 1), in: content),
              let pathRange = Range(match.range(at: 2), in: content) else { return nil }
        let path = String(content[pathRange])
        // Internal CLI rows such as "[Client=lms-cli][Endpoint=getOrLoad]"
        // contain no method/path and never match the pattern above.
        guard path.hasPrefix("/") else { return nil }
        return String(content[methodRange]) + " " + path
    }
}

// MARK: - Provider

final class LMStudioProvider: PollingAgentProvider, @unchecked Sendable {
    /// A session disappears from the notch after this long without any event.
    private static let activeWindow: TimeInterval = 15 * 60
    /// A generation that never emitted its output event is considered finished.
    private static let processingTimeout: TimeInterval = 10 * 60
    /// A lone request (e.g. GET /v1/models) counts as brief activity.
    private static let requestBusyWindow: TimeInterval = 8

    private let state = LMStudioEventState()
    private let tailer: LMStudioLogTailer?

    init() {
        let cliPath = Self.resolveCLI()
        if let cliPath {
            tailer = LMStudioLogTailer(executablePath: cliPath, state: state)
        } else {
            tailer = nil
        }
        super.init(kind: .lmStudio, pollInterval: 2, busyWindow: 60)
    }

    override func start() {
        super.start()
        guard let tailer else {
            logger.info("LM Studio CLI not found — provider stays idle")
            return
        }
        tailer.start()
    }

    override func stop() {
        tailer?.stop()
        state.reset()
        super.stop()
    }

    override func discover() -> [AgentSessionSnapshot] {
        guard tailer != nil, let activity = state.snapshot() else { return [] }

        let now = Date()
        let age = now.timeIntervalSince(activity.lastEventAt)
        guard age >= 0, age < Self.activeWindow else { return [] }

        let generating: Bool
        if activity.isPredicting, let started = activity.predictionStartedAt {
            generating = now.timeIntervalSince(started) < Self.processingTimeout
        } else {
            generating = false
        }
        let recentRequest = activity.lastRequestAt
            .map { now.timeIntervalSince($0) < Self.requestBusyWindow } ?? false

        let title: String
        if let line = activity.lastRequestLine {
            title = activity.requestCount > 1 ? "\(line)  ×\(activity.requestCount)" : line
        } else {
            title = "LM Studio local API"
        }

        return [snapshot(
            rawId: "local-api",
            // Empty cwd: LM Studio is a GUI app, so the "jump to terminal"
            // button must not be offered for this session.
            cwd: "",
            title: title,
            model: activity.model,
            phase: (generating || recentRequest) ? .processing : .waitingForInput,
            pid: nil,
            lastActivity: activity.lastEventAt
        )]
    }

    /// Locate the `lms` CLI without assuming it was added to PATH.
    private static func resolveCLI() -> String? {
        // `ProcessInfo` is also a local model type in this target, so the
        // Foundation class has to be qualified explicitly.
        if let override = Foundation.ProcessInfo.processInfo.environment["LMS_CLI_PATH"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            NSHomeDirectory() + "/.lmstudio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
            "/usr/bin/lms",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
