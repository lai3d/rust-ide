import Foundation
import Testing
@testable import RustIDE
import RustIDECore

@MainActor
@Suite struct WorkspaceTabTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.rs", "b.rs", "c.rs"] {
            try "package main\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @Test func openingTheSameFileReusesItsTab() {
        let workspace = Workspace()
        let first = workspace.openFile(url("a.rs"))
        workspace.openFile(url("b.rs"))
        let again = workspace.openFile(url("a.rs"))
        #expect(first === again)
        #expect(workspace.documents.map(\.name) == ["a.rs", "b.rs"])
        #expect(workspace.activeDocument === first)
    }

    @Test func newTabsOpenNextToTheActiveOne() {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.rs"))!
        workspace.openFile(url("b.rs"))
        workspace.activate(a)
        workspace.openFile(url("c.rs"))
        #expect(workspace.documents.map(\.name) == ["a.rs", "c.rs", "b.rs"])
    }

    @Test func closingTheActiveTabSelectsItsNeighbour() {
        let workspace = Workspace()
        workspace.openFile(url("a.rs"))
        let b = workspace.openFile(url("b.rs"))!
        workspace.openFile(url("c.rs"))
        workspace.activate(b)
        workspace.closeDocument(b)
        #expect(workspace.documents.map(\.name) == ["a.rs", "c.rs"])
        #expect(workspace.activeDocument?.name == "c.rs")
        workspace.closeAllDocuments()
        #expect(workspace.documents.isEmpty && workspace.activeDocument == nil)
    }

    @Test func cyclesTabs() {
        let workspace = Workspace()
        workspace.openFile(url("a.rs"))
        workspace.openFile(url("b.rs"))
        workspace.selectAdjacentTab(1)
        #expect(workspace.activeDocument?.name == "a.rs")
        workspace.selectAdjacentTab(-1)
        #expect(workspace.activeDocument?.name == "b.rs")
    }

    @Test func editsMarkDirtyAndSaveWritesToDisk() throws {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.rs"))!
        workspace.updateText(of: a, to: "package main\n\nfunc x() {}\n")
        #expect(a.isDirty)
        workspace.save(a)
        #expect(!a.isDirty)
        #expect(try String(contentsOf: url("a.rs"), encoding: .utf8).contains("func x()"))
    }
}

@MainActor
@Suite struct WorkspaceFormattingTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func formatsOnSave() async throws {
        let fixture = try RustAnalyzerFixture(["src/main.rs": "fn main(){\nprintln!( \"hi\" );\n}\n"])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        let document = try #require(workspace.activeDocument)
        #expect(document.name == "main.rs")

        await workspace.format(document)
        #expect(document.isDirty)  // formatted in memory, not yet saved
        #expect(document.text.contains("fn main() {"))
        await workspace.saveFormatted(document)
        #expect(!document.isDirty)
        let saved = try String(contentsOf: fixture.url("src/main.rs"), encoding: .utf8)
        #expect(saved == "fn main() {\n    println!(\"hi\");\n}\n")
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceFileSystemTests {
    let dir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("pkg"), withIntermediateDirectories: true)
        dir = base.canonicalFileURL  // real path, as FSEvents reports it
        try "module example.com/fs\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        try "package widgets\n".write(to: dir.appendingPathComponent("pkg/a.rs"), atomically: true, encoding: .utf8)
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    @Test func reloadsCleanDocumentsAndFlagsDirtyOnes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)
        let main = try #require(workspace.activeDocument)
        let other = try #require(workspace.openFile(url("pkg/a.rs")))
        workspace.updateText(of: other, to: "package widgets // edited\n")

        try "package main\n\nfunc main() { println() }\n".write(to: url("main.rs"), atomically: true, encoding: .utf8)
        try "package widgets // external\n".write(to: url("pkg/a.rs"), atomically: true, encoding: .utf8)
        workspace.handleFileSystemChanges([url("main.rs").path, url("pkg/a.rs").path])

        #expect(main.text.contains("println()") && !main.isDirty)
        #expect(other.text.contains("edited") && other.hasExternalChange)
        workspace.reloadFromDisk(other)
        #expect(other.text.contains("external") && !other.isDirty && !other.hasExternalChange)
    }

    @Test func createsRenamesAndTrashes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)

        let created = try workspace.createFile(named: "b.rs", in: url("pkg"))
        #expect(try String(contentsOf: created, encoding: .utf8) == "")
        #expect(workspace.activeDocument?.name == "b.rs")
        #expect(throws: FileOperationError.self) { try workspace.createFile(named: "b.rs", in: url("pkg")) }

        let renamed = try workspace.renameItem(at: url("pkg"), to: "widgets")
        #expect(workspace.activeDocument?.url.path == renamed.appendingPathComponent("b.rs").path)
        #expect(workspace.fileTree.contains { $0.name == "widgets" })

        try workspace.trashItem(at: renamed)
        #expect(!workspace.documents.contains { $0.name == "b.rs" })
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }
}

@MainActor
@Suite struct WorkspaceSearchTests {
    @Test func searchesProjectIncludingUnsavedBuffers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-ws-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "package main\n\nfunc main() { greet() }\n".write(to: dir.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc greet() {}\n".write(to: dir.appendingPathComponent("greet.rs"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.searchQuery = "greet"
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 2)

        // Edit greet.go without saving: the search sees the buffer.
        let greet = try #require(workspace.openFile(dir.appendingPathComponent("greet.rs")))
        workspace.updateText(of: greet, to: "package main\n\nfunc greet() {}\nfunc greetAgain() {}\n")
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 3)

        let file = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.rs") })
        workspace.open(file.matches[0], in: file)
        #expect(workspace.activeDocument?.name == "main.rs")
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 2, character: 14))
        #expect(workspace.activeDocument?.revealTarget?.length == 5)

        workspace.searchOptions.regex = true
        workspace.searchQuery = "("
        await workspace.performSearch()
        #expect(workspace.searchError != nil && workspace.searchResults.isEmpty)
    }
}

@MainActor
@Suite struct WorkspaceReferencesTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func findsReferencesAcrossFilesUsingBuffers() async throws {
        let main = "mod greet;\n\nfn main() { greet::greet(); greet::greet(); }\n"
        let fixture = try RustAnalyzerFixture(["src/main.rs": main, "src/greet.rs": "pub fn greet() {}\n"])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        let document = try #require(workspace.activeDocument)
        await workspace.findReferences(in: document, at: (main as NSString).range(of: "::greet").location + 3)
        #expect(workspace.bottomTab == .references)
        #expect(workspace.referenceTitle == "3 references to ‘greet’")
        #expect(workspace.referenceResults.map { ($0.path as NSString).lastPathComponent } == ["greet.rs", "main.rs"])
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceRenameTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func renamesAcrossOpenAndClosedFiles() async throws {
        let main = "mod greet;\n\nfn main() { greet::greet() }\n"
        let fixture = try RustAnalyzerFixture(["src/main.rs": main, "src/greet.rs": "pub fn greet() {}\n"])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        let document = try #require(workspace.activeDocument)
        let offset = (main as NSString).range(of: "::greet").location + 4

        #expect(await workspace.prepareRename(in: document, at: offset) == "greet")
        #expect(await workspace.prepareRename(in: document, at: 13) == nil)  // "fn" keyword

        let error = await workspace.renameSymbol(in: document, at: offset, to: "salute")
        #expect(error == nil)
        #expect(document.text == "mod greet;\n\nfn main() { greet::salute() }\n" && document.isDirty)  // open: buffer
        #expect(try String(contentsOf: fixture.url("src/greet.rs"), encoding: .utf8) == "pub fn salute() {}\n")  // closed: disk
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceCodeActionTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func resolvesAndAppliesAssists() async throws {
        let main = "fn main() {\n    let answer = 40 + 2;\n    println!(\"{answer}\");\n}\n"
        let fixture = try RustAnalyzerFixture(["src/main.rs": main])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        let document = try #require(workspace.activeDocument)

        // rust-analyzer assists come without an edit; perform() resolves them first.
        // On a cold CI start the assists can lag the quiescent status: re-ask briefly.
        let offset = (main as NSString).range(of: "answer").location + 2
        var actions = await workspace.codeActions(in: document, at: offset)
        for _ in 0..<20 where !actions.contains(where: { $0.title.localizedCaseInsensitiveContains("explicit type") }) {
            try await Task.sleep(for: .milliseconds(500))
            actions = await workspace.codeActions(in: document, at: offset)
        }
        let explicit = try #require(actions.first { $0.title.localizedCaseInsensitiveContains("explicit type") },
                                    "\(actions.map(\.title))")
        await workspace.perform(explicit)
        #expect(document.text.contains("let answer: i32 = 40 + 2;"), "\(document.text)")
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceNavigationTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func quickOpenFindsFilesAndSymbolsAndOutlineLoads() async throws {
        let fixture = try RustAnalyzerFixture([
            "src/main.rs": "mod greet;\nmod progress;\n\nstruct Greeter;\n\nimpl Greeter {\n    fn hello(&self) {}\n}\n\nfn main() {}\n",
            "src/greet.rs": "\n",
            "src/progress/mod.rs": "mod report;\n",
            "src/progress/report.rs": "\n",
        ])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        workspace.showQuickOpen()
        #expect(workspace.quickOpenItems.map(\.title) == ["main.rs"])  // empty query: open tabs

        workspace.quickOpenQuery = "gre"
        workspace.updateQuickOpen()
        #expect(workspace.quickOpenItems.first?.title == "greet.rs")
        // Symbols arrive asynchronously: re-ask, as typing would.
        for _ in 0..<12 where !workspace.quickOpenItems.contains(where: { $0.position != nil }) {
            try await Task.sleep(for: .milliseconds(1500))
            if !workspace.quickOpenItems.contains(where: { $0.position != nil }) { workspace.updateQuickOpen() }
        }
        let symbol = try #require(workspace.quickOpenItems.first { $0.title == "Greeter" })
        workspace.open(symbol)
        #expect(!workspace.isQuickOpenVisible)
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 3, character: 7))

        await workspace.refreshOutline()
        #expect(workspace.outline.map(\.name).contains("Greeter"))
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceGitTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("git") != nil), .timeLimit(.minutes(1)))
    func tracksBranchStatusesAndBases() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-ws-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        Git.run(["init", "-q", "-b", "feature"], in: dir)
        try "module example.com/g\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        Git.run(["add", "."], in: dir)
        Git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: dir)
        try "package main\n\n// changed\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        try "package main\n".write(to: dir.appendingPathComponent("new.rs"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        for _ in 0..<50 where workspace.gitBranch == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(workspace.gitBranch == "feature")
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("main.rs")) == .modified)
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("new.rs")) == .untracked)
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("go.mod")) == nil)
        let main = try #require(workspace.activeDocument)
        #expect(workspace.gitBase(for: main) == "package main\n\nfunc main() {}\n")
        let changes = LineChanges.compute(base: workspace.gitBase(for: main)!, current: main.text)
        #expect(changes.lines == [2: .added])
    }
}

@MainActor
@Suite(.serialized) struct SessionRestoreTests {
    @Test func restoresTabsAndRecents() async throws {
        let suite = "rustide-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        SessionStore.defaults = defaults
        defer {
            SessionStore.defaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        for name in ["main.rs", "a.rs", "b.rs"] {
            try "package main\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let first = Workspace()
        await first.openFolder(dir)
        #expect(first.documents.map(\.name) == ["main.rs"])  // nothing saved yet: default file
        first.openFile(dir.appendingPathComponent("a.rs"))
        first.openFile(dir.appendingPathComponent("b.rs"))
        first.activate(first.documents[1])  // a.go
        await first.shutdown()

        let second = Workspace()
        await second.openFolder(dir)
        #expect(second.documents.map(\.name) == ["main.rs", "a.rs", "b.rs"])
        #expect(second.activeDocument?.name == "a.rs")
        #expect(SessionStore.recentProjects.first?.path == dir.path)
        await second.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceReplaceTests {
    @Test func replacesInOpenBuffersAndOnDisk() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "package main\n\nfunc main() { getUser(); getName() }\n".write(to: dir.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other.rs")
        try "package main\n\nfunc getUser() {}\nfunc getName() {}\n".write(to: other, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        workspace.searchOptions = SearchOptions(regex: true)
        workspace.searchQuery = #"get(\w+)\("#
        workspace.replaceQuery = "fetch$1("
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 4)

        // One match first: the second call in main.go (still in the buffer).
        let mainResult = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.rs") })
        await workspace.replace(mainResult.matches[1], in: mainResult)
        #expect(main.text.contains("getUser(); fetchName()") && main.isDirty)

        #expect(await workspace.replaceAllInProject() == 3)
        #expect(main.text.contains("fetchUser(); fetchName()"))
        #expect(try String(contentsOf: other, encoding: .utf8) == "package main\n\nfunc fetchUser() {}\nfunc fetchName() {}\n")
        #expect(workspace.searchMatchCount == 0)
    }
}

@MainActor
@Suite struct WorkspaceImplementationTests {
    @Test(.enabled(if: RustAnalyzerFixture.available), .timeLimit(.minutes(2)))
    func findsImplementationsAndTypeDefinitions() async throws {
        let source = """
            trait Shape {
                fn area(&self) -> f64;
            }

            struct Square {
                s: f64,
            }

            impl Shape for Square {
                fn area(&self) -> f64 { self.s * self.s }
            }

            struct Circle {
                r: f64,
            }

            impl Shape for Circle {
                fn area(&self) -> f64 { 3.0 * self.r * self.r }
            }

            fn main() {
                let sq = Square { s: 2.0 };
                let _ = &sq;
            }

            """
        let fixture = try RustAnalyzerFixture(["src/main.rs": source])
        defer { fixture.remove() }
        let workspace = try await fixture.openWorkspace()
        let main = try #require(workspace.activeDocument)
        let ns = main.text as NSString

        // Trait with two implementations: listed.
        await workspace.jumpToImplementation(from: main, at: ns.range(of: "Shape").location + 1)
        #expect(workspace.referenceTitle == "2 implementations of ‘Shape’")
        #expect(workspace.referenceResults.first?.matches.count == 2)

        // Variable → its type: jumps (one location).
        await workspace.jumpToTypeDefinition(from: main, at: ns.range(of: "&sq").location + 2)
        #expect(main.revealTarget?.position == TextPosition(line: 4, character: 7))  // struct Square
        await workspace.shutdown()
    }
}


/// A temp Cargo crate opened in a real Workspace, waiting until rust-analyzer is quiescent.
@MainActor
struct RustAnalyzerFixture {
    nonisolated static var available: Bool {
        guard let server = RustIDECore.ToolLocator.find("rust-analyzer") else { return false }
        let process = Process()
        process.executableURL = server
        process.arguments = ["--version"]
        process.environment = RustIDECore.ToolLocator.environment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    let dir: URL

    init(_ files: [String: String]) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-ws-\(UUID().uuidString)")
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
    }

    func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    func openWorkspace() async throws -> Workspace {
        let workspace = Workspace()
        await workspace.openFolder(dir)
        for _ in 0..<900 where workspace.lspStatus != "rust-analyzer: ready" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(workspace.lspStatus == "rust-analyzer: ready")
        return workspace
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

@MainActor
@Suite struct WorkspaceCargoTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("cargo") != nil), .timeLimit(.minutes(2)))
    func derivesRunConfigurationsAndRunsThem() async throws {
        let fixture = try RustAnalyzerFixture([
            "src/main.rs": "fn main() {\n    println!(\"hello from main {:?}\", std::env::args().skip(1).collect::<Vec<_>>());\n}\n",
            "src/bin/extra.rs": "fn main() {\n    println!(\"extra {}\", std::env::var(\"GREETING\").unwrap_or_default());\n}\n",
        ])
        defer { fixture.remove() }
        let workspace = Workspace()
        await workspace.openFolder(fixture.dir)
        #expect(Set(workspace.runConfigurations.map(\.name)) == ["fixture", "extra"])
        #expect(workspace.activeDocument?.name == "main.rs")  // default file: src/main.rs

        func run(_ name: String) async throws -> String {
            workspace.selectedRunConfigurationID = workspace.runConfigurations.first { $0.name == name }?.id
            workspace.runSelectedConfiguration()
            #expect(workspace.isRunning)
            for _ in 0..<1200 where workspace.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            return workspace.output
        }
        workspace.runConfigurations[workspace.runConfigurations.firstIndex { $0.name == "fixture" }!].arguments = #"a "b c""#
        let mainOutput = try await run("fixture")
        #expect(mainOutput.hasPrefix("$ cargo run -p fixture --bin fixture -- a \"b c\""), "\(mainOutput)")
        #expect(mainOutput.contains(#"hello from main ["a", "b c"]"#), "\(mainOutput)")

        workspace.runConfigurations[workspace.runConfigurations.firstIndex { $0.name == "extra" }!].environment = "GREETING=hi"
        let extraOutput = try await run("extra")
        #expect(extraOutput.contains("extra hi"), "\(extraOutput)")
        await workspace.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceCargoTestTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("cargo") != nil), .timeLimit(.minutes(3)))
    func runsAllTestsThenTheOneAtTheCaret() async throws {
        let lib = """
            pub mod math;

            #[cfg(test)]
            mod tests {
                #[test]
                fn passes() {
                    assert_eq!(1 + 1, 2);
                }

                #[test]
                fn fails() {
                    assert_eq!(1 + 1, 3, "math is broken");
                }
            }

            """
        let math = "pub fn double(x: i32) -> i32 {\n    x * 2\n}\n\n#[test]\nfn doubles() {\n    assert_eq!(double(2), 4);\n}\n"
        let fixture = try RustAnalyzerFixture(["src/lib.rs": lib, "src/math.rs": math])
        defer { fixture.remove() }
        let workspace = Workspace()
        await workspace.openFolder(fixture.dir)
        func waitForRun() async throws {
            for _ in 0..<1500 where workspace.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        }

        workspace.runTests(.all)
        try await waitForRun()
        let report = workspace.testReport
        #expect(Set(report.tests.map(\.name)) == ["tests::passes", "tests::fails", "math::doubles"], "\(workspace.output)")
        #expect(report.failed == 1 && report.passed == 2)
        #expect(workspace.selectedTestID == report.tests.first { $0.name == "tests::fails" }?.id)  // first failure selected
        #expect(report.tests.first { $0.name == "tests::fails" }?.output.contains("math is broken") == true)
        #expect(workspace.testStatuses["math::doubles"] == .passed)

        // Caret inside `doubles` in src/math.rs: runs exactly that test, named with the file's module path.
        let document = try #require(workspace.openFile(fixture.url("src/math.rs")))
        #expect(workspace.testModulePath(for: document) == "math")
        document.caretOffset = (math as NSString).range(of: "double(2)").location
        workspace.runTestAtCaret()
        try await waitForRun()
        #expect(workspace.output.hasPrefix("$ cargo test -p fixture --lib -- math::doubles --exact"), "\(workspace.output)")
        #expect(workspace.testReport.tests.map(\.name) == ["math::doubles"])
        #expect(workspace.testReport.passed == 1)
        await workspace.shutdown()
    }
}
