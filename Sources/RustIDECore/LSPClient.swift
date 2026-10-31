import Foundation

/// A minimal JSON-RPC / LSP client that talks to a language server over stdio.
public final class LSPClient: @unchecked Sendable {
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue) -> Void
    public typealias ExitHandler = @Sendable (_ status: Int32) -> Void
    /// Answers a request from the server (e.g. `workspace/applyEdit`); nil = default answer.
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue) async -> JSONValue?

    public enum ClientError: Error, LocalizedError {
        case notRunning
        case server(code: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: "language server is not running"
            case .server(let code, let message): "server error \(code): \(message)"
            }
        }
    }

    private let lock = NSLock()
    /// Set RUSTIDE_LSP_TRACE=1 to log every message to stderr.
    private static let trace = ProcessInfo.processInfo.environment["RUSTIDE_LSP_TRACE"] != nil
    private var process: Process?
    private var stdin: FileHandle?
    private var framer = LSPFramer()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var _onNotification: NotificationHandler?
    private var _onExit: ExitHandler?
    private var _onRequest: RequestHandler?

    public init() {}

    /// Called (on a background thread) for every server notification.
    public var onNotification: NotificationHandler? {
        get { lock.withLock { _onNotification } }
        set { lock.withLock { _onNotification = newValue } }
    }

    /// Called (on a background thread) when the server process exits.
    public var onExit: ExitHandler? {
        get { lock.withLock { _onExit } }
        set { lock.withLock { _onExit = newValue } }
    }

    /// Called (on a background task) for requests the server sends to the client.
    public var onRequest: RequestHandler? {
        get { lock.withLock { _onRequest } }
        set { lock.withLock { _onRequest = newValue } }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    public func start(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            // Drain stderr so the server never blocks on a full pipe.
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        p.terminationHandler = { [weak self] proc in
            self?.handleExit(proc.terminationStatus)
        }

        try p.run()
        lock.withLock {
            process = p
            stdin = inPipe.fileHandleForWriting
        }
    }

    /// Sends a request and waits for its result.
    public func request(_ method: String, params: JSONValue = .null) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int = lock.withLock {
                let id = nextID
                nextID += 1
                pending[id] = continuation
                return id
            }
            do {
                try send(Self.message(id: .int(id), method: method, params: params))
            } catch {
                if let c = lock.withLock({ pending.removeValue(forKey: id) }) {
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// Sends a notification (no response expected).
    public func notify(_ method: String, params: JSONValue = .null) throws {
        try send(Self.message(id: nil, method: method, params: params))
    }

    /// Politely shuts the server down, terminating it if it does not exit in time.
    public func shutdown() async {
        let watchdog = Task { [self] in
            try? await Task.sleep(for: .seconds(2))
            terminateIfRunning()
        }
        _ = try? await request("shutdown")
        try? notify("exit")
        try? await Task.sleep(for: .milliseconds(200))
        terminateIfRunning()
        watchdog.cancel()
    }

    // MARK: - Private

    private static func message(id: JSONValue?, method: String, params: JSONValue) -> JSONValue {
        var obj: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { obj["id"] = id }
        if !params.isNull { obj["params"] = params }
        return .object(obj)
    }

    private func send(_ message: JSONValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let body = try encoder.encode(message)
        if Self.trace { FileHandle.standardError.write(Data("--> ".utf8) + body + Data("\n".utf8)) }
        let data = LSPFramer.frame(body)
        try lock.withLock {
            guard let stdin else { throw ClientError.notRunning }
            try stdin.write(contentsOf: data)
        }
    }

    private func receive(_ data: Data) {
        let bodies = lock.withLock { framer.append(data) }
        let decoder = JSONDecoder()
        for body in bodies {
            if Self.trace { FileHandle.standardError.write(Data("<-- ".utf8) + body + Data("\n".utf8)) }
            guard let message = try? decoder.decode(JSONValue.self, from: body) else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: JSONValue) {
        let params = message["params"] ?? .null
        if let method = message["method"]?.stringValue {
            if let id = message["id"] {
                handleServerRequest(id: id, method: method, params: params)
            } else {
                onNotification?(method, params)
            }
        } else if let id = message["id"]?.intValue {
            guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: ClientError.server(
                    code: error["code"]?.intValue ?? 0,
                    message: error["message"]?.stringValue ?? "unknown error"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
        }
    }

    /// Answers requests the server sends to the client: via `onRequest`, else safe defaults.
    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) {
        guard let handler = onRequest else {
            try? send(["jsonrpc": "2.0", "id": id, "result": Self.defaultResult(method, params)])
            return
        }
        Task { [self] in
            let result = await handler(method, params) ?? Self.defaultResult(method, params)
            try? send(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    private static func defaultResult(_ method: String, _ params: JSONValue) -> JSONValue {
        switch method {
        case "workspace/configuration":
            let count = params["items"]?.arrayValue?.count ?? 0
            return .array(Array(repeating: .null, count: count))
        case "workspace/applyEdit":
            return ["applied": false]
        default:
            return .null
        }
    }

    private func handleExit(_ status: Int32) {
        let (waiters, exitHandler) = lock.withLock {
            let waiters = Array(pending.values)
            pending.removeAll()
            stdin = nil
            process = nil
            return (waiters, _onExit)
        }
        for waiter in waiters { waiter.resume(throwing: ClientError.notRunning) }
        exitHandler?(status)
    }

    private func terminateIfRunning() {
        let p = lock.withLock { process }
        if let p, p.isRunning { p.terminate() }
    }
}
