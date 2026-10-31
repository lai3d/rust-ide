import Foundation
import Testing
@testable import RustIDECore

@Suite struct DirectoryWatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func reportsCreatedFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let watcher = try #require(DirectoryWatcher(url: dir.canonicalFileURL) { continuation.yield($0) })
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))  // let the stream start
        try "package x\n".write(to: dir.appendingPathComponent("new.rs"), atomically: true, encoding: .utf8)

        for await paths in stream where paths.contains(where: { $0.hasSuffix("/new.rs") }) {
            return  // success
        }
    }
}
