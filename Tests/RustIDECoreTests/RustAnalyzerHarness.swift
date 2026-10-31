import Foundation
import Testing
@testable import RustIDECore

/// A throwaway Cargo crate with a real rust-analyzer attached, for end-to-end LSP tests.
/// Each test gets its own crate; at most two servers run at once (each indexes std).
final class RustAnalyzerHarness: @unchecked Sendable {
    /// rust-analyzer and cargo installed and working (rustup's proxy exits non-zero without the component).
    static let available: Bool = {
        guard let server = ToolLocator.find("rust-analyzer"), ToolLocator.find("cargo") != nil else { return false }
        let process = Process()
        process.executableURL = server
        process.arguments = ["--version"]
        process.environment = ToolLocator.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    let dir: URL
    let client = LSPClient()
    private(set) var semanticLegend: SemanticTokenLegend?
    private let notifications = NotificationLog()

    /// `files` maps crate-relative paths (e.g. "src/main.rs") to contents; Cargo.toml is added if missing.
    init(files: [String: String], textDocument: JSONValue = [:], settings: JSONValue? = nil) async throws {
        await Self.slots.acquire()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-ra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base.canonicalFileURL
        var files = files
        if files["Cargo.toml"] == nil {
            files["Cargo.toml"] = "[package]\nname = \"fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
        }
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        let log = notifications
        client.onNotification = { method, params in log.record(method, params) }
        try client.start(executable: try #require(ToolLocator.find("rust-analyzer")),
                         environment: ToolLocator.environment(), currentDirectory: dir)
        let initialized = try await client.request("initialize", params: [
            "processId": .int(Int(getpid())),
            "rootUri": .string(dir.absoluteString),
            "initializationOptions": settings ?? Self.testSettings,
            "capabilities": [
                "textDocument": textDocument,
                "window": ["workDoneProgress": true],
                "experimental": ["serverStatusNotification": true],
            ],
        ])
        semanticLegend = SemanticTokenLegend(initializeResult: initialized)
        try client.notify("initialized", params: [:])
    }

    /// The app's settings, minus `cargo check` on save (slow, and most tests don't need it).
    static var testSettings: JSONValue {
        guard case .object(var settings) = RustAnalyzerSettings.default else { return RustAnalyzerSettings.default }
        settings["checkOnSave"] = false
        return .object(settings)
    }

    func url(_ path: String) -> URL { dir.appendingPathComponent(path) }
    func uri(_ path: String) -> JSONValue { .string(url(path).absoluteString) }

    /// Opens files (didOpen with their on-disk text), then waits until the server is quiescent.
    func open(_ paths: String..., timeout: Duration = .seconds(90)) async throws {
        for path in paths {
            let text = try String(contentsOf: url(path), encoding: .utf8)
            try client.notify("textDocument/didOpen", params: [
                "textDocument": ["uri": uri(path), "languageId": "rust", "version": 1, "text": .string(text)],
            ])
        }
        try await waitUntilQuiescent(timeout: timeout)
    }

    func waitUntilQuiescent(timeout: Duration = .seconds(90)) async throws {
        _ = try await notifications.wait(timeout: timeout) { method, params in
            method == "experimental/serverStatus" && params["quiescent"]?.boolValue == true
        }
    }

    /// Waits for the first notification matching `predicate` (including ones already received).
    func waitFor(timeout: Duration = .seconds(90),
                 _ predicate: @escaping @Sendable (String, JSONValue) -> Bool) async throws -> JSONValue {
        try await notifications.wait(timeout: timeout, predicate)
    }

    /// `{textDocument, position}` params.
    func at(_ path: String, _ line: Int, _ character: Int) -> JSONValue {
        ["textDocument": ["uri": uri(path)], "position": TextPosition(line: line, character: character).json]
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await client.request(method, params: params)
    }

    func shutdown() async {
        await client.shutdown()
        try? FileManager.default.removeItem(at: dir)
        await Self.slots.release()
    }

    private static let slots = AsyncSemaphore(2)
}

/// Every notification received, so a waiter never misses one that arrived first.
private final class NotificationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(String, JSONValue)] = []

    func record(_ method: String, _ params: JSONValue) {
        lock.withLock { received.append((method, params)) }
    }

    func wait(timeout: Duration, _ predicate: @escaping @Sendable (String, JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = lock.withLock({ received.first { predicate($0.0, $0.1) } }) { return match.1 }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct Timeout: Error {}
        throw Timeout()
    }
}

actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
