import Foundation
import Testing
@testable import RustIDE
import RustIDECore

@MainActor
@Suite struct WorkspaceTabTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.go", "b.go", "c.go"] {
            try "package main\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @Test func openingTheSameFileReusesItsTab() {
        let workspace = Workspace()
        let first = workspace.openFile(url("a.go"))
        workspace.openFile(url("b.go"))
        let again = workspace.openFile(url("a.go"))
        #expect(first === again)
        #expect(workspace.documents.map(\.name) == ["a.go", "b.go"])
        #expect(workspace.activeDocument === first)
    }

    @Test func newTabsOpenNextToTheActiveOne() {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.go"))!
        workspace.openFile(url("b.go"))
        workspace.activate(a)
        workspace.openFile(url("c.go"))
        #expect(workspace.documents.map(\.name) == ["a.go", "c.go", "b.go"])
    }

    @Test func closingTheActiveTabSelectsItsNeighbour() {
        let workspace = Workspace()
        workspace.openFile(url("a.go"))
        let b = workspace.openFile(url("b.go"))!
        workspace.openFile(url("c.go"))
        workspace.activate(b)
        workspace.closeDocument(b)
        #expect(workspace.documents.map(\.name) == ["a.go", "c.go"])
        #expect(workspace.activeDocument?.name == "c.go")
        workspace.closeAllDocuments()
        #expect(workspace.documents.isEmpty && workspace.activeDocument == nil)
    }

    @Test func cyclesTabs() {
        let workspace = Workspace()
        workspace.openFile(url("a.go"))
        workspace.openFile(url("b.go"))
        workspace.selectAdjacentTab(1)
        #expect(workspace.activeDocument?.name == "a.go")
        workspace.selectAdjacentTab(-1)
        #expect(workspace.activeDocument?.name == "b.go")
    }

    @Test func editsMarkDirtyAndSaveWritesToDisk() throws {
        let workspace = Workspace()
        let a = workspace.openFile(url("a.go"))!
        workspace.updateText(of: a, to: "package main\n\nfunc x() {}\n")
        #expect(a.isDirty)
        workspace.save(a)
        #expect(!a.isDirty)
        #expect(try String(contentsOf: url("a.go"), encoding: .utf8).contains("func x()"))
    }
}

@MainActor
@Suite struct WorkspaceFormattingTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func formatsAndOrganizesImportsOnSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goide-wsfmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "module example.com/t\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("main.go")
        try "package main\n\nfunc main(){\nfmt.Println( \"hi\" )\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let document = try #require(workspace.activeDocument)
        #expect(workspace.lspStatus == "gopls: ready")

        await workspace.format(document)
        #expect(document.isDirty)  // formatted in memory, not yet saved
        #expect(document.text.contains("func main() {"))
        await workspace.saveFormatted(document)
        #expect(!document.isDirty)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"hi\")\n}\n")
    }
}

@MainActor
@Suite struct WorkspaceFileSystemTests {
    let dir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("pkg"), withIntermediateDirectories: true)
        dir = base.canonicalFileURL  // real path, as FSEvents reports it
        try "module example.com/fs\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package widgets\n".write(to: dir.appendingPathComponent("pkg/a.go"), atomically: true, encoding: .utf8)
    }

    private func url(_ path: String) -> URL { dir.appendingPathComponent(path) }

    @Test func reloadsCleanDocumentsAndFlagsDirtyOnes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)
        let main = try #require(workspace.activeDocument)
        let other = try #require(workspace.openFile(url("pkg/a.go")))
        workspace.updateText(of: other, to: "package widgets // edited\n")

        try "package main\n\nfunc main() { println() }\n".write(to: url("main.go"), atomically: true, encoding: .utf8)
        try "package widgets // external\n".write(to: url("pkg/a.go"), atomically: true, encoding: .utf8)
        workspace.handleFileSystemChanges([url("main.go").path, url("pkg/a.go").path])

        #expect(main.text.contains("println()") && !main.isDirty)
        #expect(other.text.contains("edited") && other.hasExternalChange)
        workspace.reloadFromDisk(other)
        #expect(other.text.contains("external") && !other.isDirty && !other.hasExternalChange)
    }

    @Test func createsRenamesAndTrashes() async throws {
        let workspace = Workspace()
        await workspace.openFolder(dir.canonicalFileURL)

        let created = try workspace.createFile(named: "b.go", in: url("pkg"))
        #expect(try String(contentsOf: created, encoding: .utf8) == "package widgets\n")
        #expect(workspace.activeDocument?.name == "b.go")
        #expect(throws: FileOperationError.self) { try workspace.createFile(named: "b.go", in: url("pkg")) }

        let renamed = try workspace.renameItem(at: url("pkg"), to: "widgets")
        #expect(workspace.activeDocument?.url.path == renamed.appendingPathComponent("b.go").path)
        #expect(workspace.fileTree.contains { $0.name == "widgets" })

        try workspace.trashItem(at: renamed)
        #expect(!workspace.documents.contains { $0.name == "b.go" })
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
    }

    @Test func derivesPackageNames() throws {
        try FileManager.default.createDirectory(at: url("My-Tool"), withIntermediateDirectories: true)
        #expect(Workspace.packageName(for: url("My-Tool")) == "mytool")
        #expect(Workspace.packageName(for: dir) == "main")
    }
}

@MainActor
@Suite struct WorkspaceSearchTests {
    @Test func searchesProjectIncludingUnsavedBuffers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "package main\n\nfunc main() { greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc greet() {}\n".write(to: dir.appendingPathComponent("greet.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.searchQuery = "greet"
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 2)

        // Edit greet.go without saving: the search sees the buffer.
        let greet = try #require(workspace.openFile(dir.appendingPathComponent("greet.go")))
        workspace.updateText(of: greet, to: "package main\n\nfunc greet() {}\nfunc greetAgain() {}\n")
        await workspace.performSearch()
        #expect(workspace.searchMatchCount == 3)

        let file = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.go") })
        workspace.open(file.matches[0], in: file)
        #expect(workspace.activeDocument?.name == "main.go")
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
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func findsReferencesAcrossFilesUsingBuffers() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/r\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() { greet(); greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc greet() {}\n".write(to: dir.appendingPathComponent("greet.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        await workspace.findReferences(in: main, at: ("package main\n\nfunc main() { " as NSString).length + 1)
        #expect(workspace.bottomTab == .references)
        #expect(workspace.referenceTitle == "3 references to ‘greet’")
        #expect(workspace.referenceResults.map { ($0.path as NSString).lastPathComponent } == ["greet.go", "main.go"])
    }
}

@MainActor
@Suite struct WorkspaceRenameTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func renamesAcrossOpenAndClosedFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/r\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() { greet() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        let greetFile = dir.appendingPathComponent("greet.go")
        try "package main\n\nfunc greet() {}\n".write(to: greetFile, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        let offset = ("package main\n\nfunc main() { " as NSString).length + 2

        #expect(await workspace.prepareRename(in: main, at: offset) == "greet")
        #expect(await workspace.prepareRename(in: main, at: 2) == nil)  // "package" keyword

        let error = await workspace.renameSymbol(in: main, at: offset, to: "salute")
        #expect(error == nil)
        #expect(main.text == "package main\n\nfunc main() { salute() }\n" && main.isDirty)  // open: buffer
        #expect(try String(contentsOf: greetFile, encoding: .utf8) == "package main\n\nfunc salute() {}\n")  // closed: disk
    }
}

@MainActor
@Suite struct WorkspaceCodeActionTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func appliesEditActionsAndCommandActions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/ca\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nimport \"os\"\n\nfunc Add(a, b int) int { return a + b }\n\nfunc main() {}\n"
            .write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        // Wait for gopls to publish the unused-import diagnostic.
        for _ in 0..<50 where workspace.diagnostics(for: main).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let importOffset = ("package main\n\nimport \"" as NSString).length

        // An action with an edit.
        let actions = await workspace.codeActions(in: main, at: importOffset)
        let organize = try #require(actions.first { $0.kind == "source.organizeImports" })
        await workspace.perform(organize)
        #expect(!main.text.contains("\"os\""))

        // A command action: gopls answers with workspace/applyEdit creating main_test.go.
        let addOffset = ("package main\n\nfunc Ad" as NSString).length
        let addTest = try #require(await workspace.codeActions(in: main, at: addOffset).first { $0.kind == "source.addTest" })
        await workspace.perform(addTest)
        let testFile = dir.appendingPathComponent("main_test.go")
        for _ in 0..<50 where workspace.activeDocument?.name != "main_test.go" { try await Task.sleep(for: .milliseconds(100)) }
        #expect(workspace.activeDocument?.name == "main_test.go")
        #expect(workspace.activeDocument?.text.contains("func TestAdd") == true)
        #expect(FileManager.default.fileExists(atPath: testFile.path))
    }
}

@MainActor
@Suite struct WorkspaceNavigationTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func quickOpenFindsFilesAndSymbolsAndOutlineLoads() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("internal/progress"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/nav\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\ntype Greeter struct{}\n\nfunc (Greeter) Hello() {}\n\nfunc main() {}\n"
            .write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n".write(to: dir.appendingPathComponent("greet.go"), atomically: true, encoding: .utf8)
        try "package progress\n".write(to: dir.appendingPathComponent("internal/progress/report.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        workspace.showQuickOpen()
        #expect(workspace.quickOpenItems.map(\.title) == ["main.go"])  // empty query: open tabs

        workspace.quickOpenQuery = "gre"
        workspace.updateQuickOpen()
        #expect(workspace.quickOpenItems.first?.title == "greet.go")
        // gopls may still be loading packages on a cold (CI) start: re-ask, as typing would.
        // (Each re-ask cancels the request in flight, so leave it time to answer.)
        for _ in 0..<12 where !workspace.quickOpenItems.contains(where: { $0.position != nil }) {
            try await Task.sleep(for: .milliseconds(1500))
            if !workspace.quickOpenItems.contains(where: { $0.position != nil }) { workspace.updateQuickOpen() }
        }
        let symbol = try #require(workspace.quickOpenItems.first { $0.title == "Greeter" })
        workspace.open(symbol)
        #expect(!workspace.isQuickOpenVisible)
        #expect(workspace.activeDocument?.revealTarget?.position == TextPosition(line: 2, character: 5))

        await workspace.refreshOutline()
        #expect(workspace.outline.map(\.name).contains("Greeter"))
    }
}

@MainActor
@Suite struct WorkspaceGitTests {
    @Test(.enabled(if: RustIDECore.ToolLocator.find("git") != nil), .timeLimit(.minutes(1)))
    func tracksBranchStatusesAndBases() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-ws-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        Git.run(["init", "-q", "-b", "feature"], in: dir)
        try "module example.com/g\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        try "package main\n\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        Git.run(["add", "."], in: dir)
        Git.run(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: dir)
        try "package main\n\n// changed\nfunc main() {}\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        try "package main\n".write(to: dir.appendingPathComponent("new.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        for _ in 0..<50 where workspace.gitBranch == nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(workspace.gitBranch == "feature")
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("main.go")) == .modified)
        #expect(workspace.gitStatus(for: dir.appendingPathComponent("new.go")) == .untracked)
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
        let suite = "goide-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        SessionStore.defaults = defaults
        defer {
            SessionStore.defaults = .standard
            defaults.removePersistentDomain(forName: suite)
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        for name in ["main.go", "a.go", "b.go"] {
            try "package main\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let first = Workspace()
        await first.openFolder(dir)
        #expect(first.documents.map(\.name) == ["main.go"])  // nothing saved yet: default file
        first.openFile(dir.appendingPathComponent("a.go"))
        first.openFile(dir.appendingPathComponent("b.go"))
        first.activate(first.documents[1])  // a.go
        await first.shutdown()

        let second = Workspace()
        await second.openFolder(dir)
        #expect(second.documents.map(\.name) == ["main.go", "a.go", "b.go"])
        #expect(second.activeDocument?.name == "a.go")
        #expect(SessionStore.recentProjects.first?.path == dir.path)
        await second.shutdown()
    }
}

@MainActor
@Suite struct WorkspaceReplaceTests {
    @Test func replacesInOpenBuffersAndOnDisk() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "package main\n\nfunc main() { getUser(); getName() }\n".write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other.go")
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
        let mainResult = try #require(workspace.searchResults.first { $0.path.hasSuffix("main.go") })
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
    @Test(.enabled(if: RustIDECore.ToolLocator.find("gopls") != nil), .timeLimit(.minutes(1)))
    func findsImplementationsAndTypeDefinitions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("goide-impl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.canonicalFileURL
        try "module example.com/impl\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
        let source = """
            package main

            type Shape interface{ Area() float64 }

            type Square struct{ s float64 }

            func (q Square) Area() float64 { return q.s * q.s }

            type Circle struct{ r float64 }

            func (c Circle) Area() float64 { return 3 * c.r * c.r }

            func main() {
            \tsq := Square{2}
            \t_ = sq
            }

            """
        try source.write(to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        await workspace.openFolder(dir)
        let main = try #require(workspace.activeDocument)
        let ns = main.text as NSString

        // Interface with two implementations: listed.
        await workspace.jumpToImplementation(from: main, at: ns.range(of: "Shape").location + 1)
        #expect(workspace.referenceTitle == "2 implementations of ‘Shape’")
        #expect(workspace.referenceResults.first?.matches.count == 2)

        // Variable → its type: jumps (one location).
        await workspace.jumpToTypeDefinition(from: main, at: ns.range(of: "_ = sq").location + 5)
        #expect(main.revealTarget?.position == TextPosition(line: 4, character: 5))  // type Square
    }
}
