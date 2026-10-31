import Foundation
import Testing
@testable import RustIDECore

@Suite struct DAPTests {
    @Test(.enabled(if: ToolLocator.find("dlv") != nil), .timeLimit(.minutes(2)))
    func launchesBreaksInspectsAndContinues() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-dap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/dbg\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("main.go")
        try """
            package main

            import "fmt"

            type point struct{ X, Y int }

            func main() {
            \tp := point{X: 3, Y: 4}
            \ttotal := p.X + p.Y
            \tfmt.Println("total", total)
            }

            """.write(to: main, atomically: true, encoding: .utf8)

        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        try await client.start(dlv: try #require(ToolLocator.find("dlv")), directory: dir,
                               environment: ToolLocator.environment())
        _ = try await client.request("initialize", arguments: [
            "clientID": "goide", "adapterID": "go", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path",
        ])
        _ = try await client.request("launch", arguments: [
            "request": "launch", "mode": "debug", "program": .string(dir.path), "outputMode": "remote",
        ])
        await client.waitForEvent("initialized")
        let set = try await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(main.path)], "breakpoints": [["line": 9]],
        ])
        #expect(set["breakpoints"]?[0]?["verified"]?.boolValue == true)
        _ = try await client.request("configurationDone")

        var stoppedThread: Int?
        var sawOutput = false
        for await (event, body) in events {
            if event == "stopped" { stoppedThread = body["threadId"]?.intValue; break }
        }
        let thread = try #require(stoppedThread)
        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 20]))
        #expect(frames.first?.name == "main.main" && frames.first?.line == 9)

        let scopes = DebugVariable.parseScopes(try await client.request("scopes", arguments: ["frameId": .int(frames[0].id)]))
        let locals = try #require(scopes.first { $0.name == "Locals" })
        let variables = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(locals.variablesReference),
        ]))
        let p = try #require(variables.first { $0.name == "p" })
        #expect(p.value.contains("X: 3") && p.variablesReference > 0)
        let fields = DebugVariable.parseVariables(try await client.request("variables", arguments: [
            "variablesReference": .int(p.variablesReference),
        ]))
        #expect(fields.map(\.name) == ["X", "Y"])

        _ = try await client.request("next", arguments: ["threadId": .int(thread)])
        for await (event, _) in events where event == "stopped" { break }
        let afterStep = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(thread), "levels": 1]))
        #expect(afterStep.first?.line == 10)

        _ = try await client.request("continue", arguments: ["threadId": .int(thread)])
        for await (event, body) in events {
            if event == "output", body["output"]?.stringValue?.contains("total 7") == true { sawOutput = true }
            if event == "terminated" { break }
        }
        #expect(sawOutput)
        await client.shutdown()
    }
}

@Suite struct DAPExtrasTests {
    @Test(.enabled(if: ToolLocator.find("dlv") != nil), .timeLimit(.minutes(2)))
    func conditionalBreakpointAndEvaluate() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-dapx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/dbg\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("main.go")
        try """
            package main

            func main() {
            \ttotal := 0
            \tfor i := 0; i < 10; i++ {
            \t\ttotal += i
            \t}
            \tprintln(total)
            }

            """.write(to: main, atomically: true, encoding: .utf8)

        let client = DAPClient()
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        client.onEvent = { continuation.yield(($0, $1)) }
        try await client.start(dlv: try #require(ToolLocator.find("dlv")), directory: dir, environment: ToolLocator.environment())
        try await client.request("initialize", arguments: ["adapterID": "go", "linesStartAt1": true, "pathFormat": "path"])
        try await client.request("launch", arguments: [
            "request": "launch", "mode": "debug", "program": .string(dir.path),
            "output": .string(base.appendingPathComponent("bin").path),
        ])
        await client.waitForEvent("initialized")
        try await client.request("setBreakpoints", arguments: [
            "source": ["path": .string(main.path)], "breakpoints": [["line": 6, "condition": "i == 7"]],
        ])
        try await client.request("configurationDone")
        var thread: Int?
        for await (event, body) in events where event == "stopped" {
            thread = body["threadId"]?.intValue
            break
        }
        let frames = StackFrame.parseAll(try await client.request("stackTrace", arguments: ["threadId": .int(try #require(thread)), "levels": 1]))
        let frame = try #require(frames.first).id
        func evaluate(_ expression: String) async throws -> String? {
            try await client.request("evaluate", arguments: ["expression": .string(expression), "frameId": .int(frame), "context": "hover"])["result"]?.stringValue
        }
        #expect(try await evaluate("i") == "7")              // stopped only when the condition held
        #expect(try await evaluate("total") == "21")         // 0+1+…+6
        #expect(try await evaluate("total * 2 + i") == "49")
        await client.shutdown()
    }
}
