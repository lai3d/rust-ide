import Foundation

/// A Debug Adapter Protocol client for `lldb-dap`, which speaks DAP over stdin/stdout.
public final class DAPClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (_ event: String, _ body: JSONValue) -> Void
    public typealias ExitHandler = @Sendable () -> Void

    public enum DAPError: Error, LocalizedError {
        case notConnected
        case adapterFailed(String)
        case request(command: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "debug adapter is not connected"
            case .adapterFailed(let message): "couldn't start lldb-dap: \(message)"
            case .request(let command, let message): "\(command): \(message)"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var writer: FileHandle?
    private var framer = LSPFramer()  // DAP uses the same Content-Length framing as LSP
    private var seq = 1
    private var pending: [Int: (command: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var seenEvents: Set<String> = []
    private var eventWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var _onEvent: EventHandler?
    private var _onExit: ExitHandler?
    private var exited = false
    private static let trace = ProcessInfo.processInfo.environment["RUSTIDE_DAP_TRACE"] != nil

    public init() {}

    /// Debug adapter events (`stopped`, `output`, `terminated`, …), on a background thread.
    public var onEvent: EventHandler? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Called once when the adapter goes away.
    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// Starts the adapter with DAP on its stdin/stdout. `stderr` receives its diagnostics.
    public func start(adapter: URL, arguments: [String] = [], directory: URL, environment: [String: String],
                      stderr: (@Sendable (String) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = adapter
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in self?.handleExit() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.handleExit()
                return
            }
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            stderr?(String(decoding: data, as: UTF8.self))
        }
        do {
            try process.run()
        } catch {
            throw DAPError.adapterFailed(error.localizedDescription)
        }
        lock.withLock {
            self.process = process
            self.writer = input.fileHandleForWriting
        }
    }

    /// Finds lldb-dap: a Settings override, then Xcode's (`xcrun -f lldb-dap`), then PATH (Homebrew llvm).
    public static func locateLLDBDAP() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: ToolLocator.overrideKey(for: "lldb-dap")), !custom.isEmpty {
            return ToolLocator.find("lldb-dap")
        }
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["-f", "lldb-dap"]
        let out = Pipe()
        xcrun.standardOutput = out
        xcrun.standardError = FileHandle.nullDevice
        if (try? xcrun.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            xcrun.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if xcrun.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return ToolLocator.find("lldb-dap") ?? ToolLocator.find("lldb-vscode")
    }

    /// Sends a request and returns the response `body` (throws if `success` is false).
    @discardableResult
    public func request(_ command: String, arguments: JSONValue = [:]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int = lock.withLock {
                let id = seq
                seq += 1
                pending[id] = (command, continuation)
                return id
            }
            do {
                try send(["seq": .int(id), "type": "request", "command": .string(command), "arguments": arguments])
            } catch {
                if let waiter = lock.withLock({ pending.removeValue(forKey: id) }) {
                    waiter.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns once `event` has been received (immediately if it already was).
    public func waitForEvent(_ event: String) async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if seenEvents.contains(event) || exited { return true }
                eventWaiters[event, default: []].append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Ends the session (and the debuggee), then stops the adapter.
    public func shutdown() async {
        _ = try? await withTimeout(seconds: 2) {
            try await self.request("disconnect", arguments: ["terminateDebuggee": true])
        }
        let process = lock.withLock { self.process }
        if let process, process.isRunning { process.terminate() }
    }

    // MARK: - Private

    private func send(_ message: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(message)
        if Self.trace { FileHandle.standardError.write(Data("DAP --> ".utf8) + body + Data("\n".utf8)) }
        try lock.withLock {
            guard let writer else { throw DAPError.notConnected }
            try writer.write(contentsOf: LSPFramer.frame(body))
        }
    }

    private func receive(_ data: Data) {
        let bodies = lock.withLock { framer.append(data) }
        for body in bodies {
            if Self.trace { FileHandle.standardError.write(Data("DAP <-- ".utf8) + body + Data("\n".utf8)) }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else { continue }
            switch message["type"]?.stringValue {
            case "response":
                guard let id = message["request_seq"]?.intValue,
                      let waiter = lock.withLock({ pending.removeValue(forKey: id) }) else { continue }
                if message["success"]?.boolValue == true {
                    waiter.continuation.resume(returning: message["body"] ?? .null)
                } else {
                    let text = message["body"]?["error"]?["format"]?.stringValue
                        ?? message["message"]?.stringValue ?? "failed"
                    waiter.continuation.resume(throwing: DAPError.request(command: waiter.command, message: text))
                }
            case "event":
                guard let event = message["event"]?.stringValue else { continue }
                let (handler, waiters) = lock.withLock {
                    seenEvents.insert(event)
                    return (_onEvent, eventWaiters.removeValue(forKey: event) ?? [])
                }
                handler?(event, message["body"] ?? .null)
                waiters.forEach { $0.resume() }
            case "request":
                // Reverse requests (e.g. runInTerminal) aren't supported: answer with an error.
                if let id = message["seq"]?.intValue, let command = message["command"]?.stringValue {
                    try? send(["seq": .int(0), "type": "response", "request_seq": .int(id),
                               "command": .string(command), "success": false, "message": "not supported"])
                }
            default:
                break
            }
        }
    }

    private func handleExit() {
        let (waiters, eventWaiters, handler, alreadyExited) = lock.withLock {
            let result = (Array(pending.values), self.eventWaiters.values.flatMap { $0 }, _onExit, exited)
            exited = true
            pending.removeAll()
            self.eventWaiters.removeAll()
            writer = nil
            return result
        }
        guard !alreadyExited else { return }
        waiters.forEach { $0.continuation.resume(throwing: DAPError.notConnected) }
        eventWaiters.forEach { $0.resume() }
        handler?()
    }
}

/// Runs `operation`, giving up after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

// MARK: - DAP models

public struct StackFrame: Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let path: String?
    /// One-based, as DAP reports by default.
    public let line: Int
    public let column: Int

    public static func parseAll(_ body: JSONValue) -> [StackFrame] {
        (body["stackFrames"]?.arrayValue ?? []).compactMap { frame in
            guard let id = frame["id"]?.intValue, let name = frame["name"]?.stringValue else { return nil }
            return StackFrame(id: id, name: name, path: frame["source"]?["path"]?.stringValue,
                              line: frame["line"]?.intValue ?? 0, column: frame["column"]?.intValue ?? 0)
        }
    }
}

public struct DebugVariable: Sendable, Hashable {
    public let name: String
    public let value: String
    public let type: String?
    /// > 0 when the value has children (struct fields, slice elements, …).
    public let variablesReference: Int

    public static func parseScopes(_ body: JSONValue) -> [DebugVariable] {
        (body["scopes"]?.arrayValue ?? []).compactMap { scope in
            guard let name = scope["name"]?.stringValue else { return nil }
            return DebugVariable(name: name, value: "", type: nil,
                                 variablesReference: scope["variablesReference"]?.intValue ?? 0)
        }
    }

    public static func parseVariables(_ body: JSONValue) -> [DebugVariable] {
        (body["variables"]?.arrayValue ?? []).compactMap { variable in
            guard let name = variable["name"]?.stringValue else { return nil }
            return DebugVariable(name: name, value: variable["value"]?.stringValue ?? "",
                                 type: variable["type"]?.stringValue,
                                 variablesReference: variable["variablesReference"]?.intValue ?? 0)
        }
    }
}
