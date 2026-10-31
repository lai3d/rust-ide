import AppKit
import RustIDECore
import Observation

enum BottomTab: Hashable {
    case problems, references, calls, tests, debug, output, terminal
}

enum EditAction: Hashable {
    case toggleComment, indent, outdent, duplicateLines, moveLinesUp, moveLinesDown
}

/// A request for the active editor to run a line-editing command (from the menu).
struct EditRequest: Equatable {
    let id = UUID()
    let action: EditAction
}

enum FoldAction: Hashable {
    case fold, unfold, foldAll, unfoldAll
}

/// A request for the active editor to fold/unfold (from the menu).
struct FoldRequest: Equatable {
    let id = UUID()
    let action: FoldAction
}

enum CallDirection: Hashable {
    case incoming, outgoing
}

/// A node in the Calls panel; children (the next level of callers/callees) load on expand.
@MainActor
@Observable
final class CallNode: Identifiable {
    let id = UUID()
    let item: CallHierarchyItem
    /// Where this call happens (caller's file for incoming, root item's file for outgoing).
    let callSite: (uri: String, position: TextPosition)?
    var children: [CallNode]?
    var isExpanded = false

    init(item: CallHierarchyItem, callSite: (uri: String, position: TextPosition)? = nil) {
        self.item = item
        self.callSite = callSite
    }
}

enum TestScope: Equatable {
    case all
    /// The Cargo package containing this file or folder.
    case package(URL)
    /// One test by full module path (`tests::adds`), in the target containing this file.
    case test(String, in: URL)
    /// A rust-analyzer runnable (test module, doctest…) with its own cargo arguments.
    case runnable(Runnable)
}

enum SidebarMode: Hashable {
    case files, search, outline, git, cargo
}

/// A row in the Open Quickly palette: a file or a symbol.
struct QuickOpenItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let url: URL
    let position: TextPosition?
    let score: Int
}

/// A request for an editor to move the caret to a position (and optionally select).
struct RevealTarget: Equatable {
    let id = UUID()
    let position: TextPosition
    var length = 0
}

struct NavigationPoint: Equatable {
    let url: URL
    let position: TextPosition
}

struct ProblemItem: Identifiable {
    let path: String
    let diagnostic: Diagnostic
    var id: UUID { diagnostic.id }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// An open file: its text buffer and per-editor state.
@MainActor
@Observable
final class Document: Identifiable {
    nonisolated let id = UUID()
    private(set) var url: URL
    let isReadOnly: Bool
    var text: String
    var isDirty = false
    /// The file changed on disk while this buffer had unsaved edits.
    var hasExternalChange = false
    var revealTarget: RevealTarget?
    @ObservationIgnored var version = 1
    /// UTF-16 caret offset, reported by the editor.
    @ObservationIgnored var caretOffset = 0 {
        didSet {
            // Observable line/column for the breadcrumbs (only when the line changes or it's cheap).
            let position = LineIndex(text).position(of: caretOffset)
            if position != caretPosition { caretPosition = position }
        }
    }
    private(set) var caretPosition = TextPosition(line: 0, character: 0)

    var name: String { url.lastPathComponent }
    var isRust: Bool { url.pathExtension == "rs" }
    /// Rust files rust-analyzer knows about: not macro expansion tabs.
    var usesLanguageServer: Bool { isRust && !Self.isExpansion(url) }

    /// Folder for macro expansion tabs (read-only, highlighted, not sent to rust-analyzer).
    nonisolated static let expansionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RustIDE-macro-expansions", isDirectory: true).canonicalFileURL

    nonisolated static func isExpansion(_ url: URL) -> Bool {
        url.canonicalFileURL.path.hasPrefix(expansionDirectory.path + "/")
    }

    init(url: URL, text: String, isReadOnly: Bool) {
        self.url = url
        self.text = text
        self.isReadOnly = isReadOnly
    }

    func move(to url: URL) {
        self.url = url
    }
}

enum FileOperationError: LocalizedError {
    case alreadyExists(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): "“\(name)” already exists."
        case .invalidName(let name): "“\(name)” is not a valid name."
        }
    }
}

/// All state for one project folder: open documents, rust-analyzer, and cargo commands.
@MainActor
@Observable
final class Workspace {
    /// The workspace of the most recently focused window (Settings, debug hooks like --snapshot).
    static weak var current: Workspace?
    /// Target for menu commands when no window is focused: has no folder, so they do nothing.
    static let placeholder = Workspace()
    private static let registry = NSHashTable<Workspace>.weakObjects()
    private static var handledLaunchArguments = false

    /// Workspaces of all open windows.
    static var allOpen: [Workspace] { registry.allObjects }

    static func register(_ workspace: Workspace) {
        registry.add(workspace)
        current = workspace
    }

    /// Releases a closing window's resources: gopls, Delve, the file watcher, running commands.
    func shutdown() async {
        Self.registry.remove(self)
        if Self.current === self { Self.current = Self.allOpen.last }
        stopDebugging()
        terminal?.terminate()
        runProcess?.terminate()
        watcher?.stop()
        watcher = nil
        await stopLanguageServer()
    }

    private(set) var rootURL: URL?
    private(set) var fileTree: [FileNode] = []
    private(set) var documents: [Document] = []
    private(set) var activeDocument: Document? {
        didSet { if activeDocument !== oldValue { saveSession() } }
    }
    private(set) var diagnostics: [String: [Diagnostic]] = [:]  // keyed by normalized path
    private(set) var lspStatus = "rust-analyzer: not started"
    /// Bumped each time gopls becomes ready, so editors can (re)request hints etc.
    private(set) var languageServerEpoch = 0
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var backStack: [NavigationPoint] = []
    var bottomTab: BottomTab = .problems
    var sidebarMode: SidebarMode = .files

    // Find in project
    var searchQuery = ""
    var searchOptions = SearchOptions()
    private(set) var searchResults: [SearchFileResult] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    var replaceQuery = ""
    var isReplaceVisible = false
    /// Bumped to ask the search field to take focus.
    private(set) var searchFocusRequest = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Bumped to ask the active editor to show its quick-fix menu (⌥↩).
    private(set) var quickFixRequest = 0
    private(set) var foldRequest: FoldRequest?
    private(set) var editRequest: EditRequest?

    func requestEdit(_ action: EditAction) {
        editRequest = EditRequest(action: action)
    }

    func requestFold(_ action: FoldAction) {
        foldRequest = FoldRequest(action: action)
    }

    // Open Quickly
    var isQuickOpenVisible = false
    var quickOpenQuery = ""
    private(set) var quickOpenItems: [QuickOpenItem] = []
    @ObservationIgnored private var quickOpenFiles: [String]?
    @ObservationIgnored private var quickOpenTask: Task<Void, Never>?

    // Outline of the active document
    private(set) var outline: [SymbolNode] = []

    // Tests
    private(set) var testReport = CargoTestReport()
    private(set) var testRunTitle = ""
    @ObservationIgnored private var lastTestScope: TestScope?
    var selectedTestID: String?
    /// Latest status per test path (`tests::adds`), for gutter markers.
    var testStatuses: [String: TestResult.Status] {
        Dictionary(testReport.tests.map { ($0.name, $0.status) }, uniquingKeysWith: { $1 })
    }

    // Debugging
    /// Breakpoints: canonical file path → one-based lines.
    private(set) var breakpoints: [String: Set<Int>] = [:]
    private(set) var debugSession: DebugSession?
    /// Breakpoint conditions: path → one-based line → condition.
    private(set) var breakpointConditions: [String: [Int: String]] = [:]
    private(set) var executionLocation: ExecutionLocation?

    // Git
    private(set) var gitBranch: String?
    private(set) var gitStatuses: [String: GitFileStatus] = [:]
    /// HEAD contents of open files (for gutter change bars), keyed by path.
    private(set) var gitBases: [String: String] = [:]
    /// The document shown as a diff against HEAD instead of its editor.
    var diffDocumentID: UUID?
    /// Staged/unstaged changes for the Source Control sidebar.
    private(set) var gitChanges: [GitChange] = []
    var commitMessage = ""
    private(set) var gitError: String?
    var isGitRepository: Bool { gitTopLevel != nil }
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    private(set) var gitTopLevel: URL?

    /// The integrated terminal (kept alive while the window is open).
    private(set) var terminal: TerminalSession?

    func showTerminal() {
        if terminal == nil {
            terminal = TerminalSession(directory: rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        bottomTab = .terminal
    }

    // Run configurations
    var runConfigurations: [RunConfiguration] = [] {
        didSet { saveRunConfigurations() }
    }
    var selectedRunConfigurationID: UUID? {
        didSet { saveRunConfigurations() }
    }
    /// `cargo metadata` for the folder (nil when it isn't a Cargo project or cargo failed).
    private(set) var cargoMetadata: CargoMetadata?
    /// Binaries and examples, for run configurations.
    var runTargets: [CargoTarget] { cargoMetadata?.runnableTargets ?? [] }
    var isEditingRunConfigurations = false

    var selectedRunConfiguration: RunConfiguration? {
        runConfigurations.first { $0.id == selectedRunConfigurationID } ?? runConfigurations.first
    }

    // Call hierarchy
    private(set) var callRoot: CallNode?
    var callDirection: CallDirection = .incoming

    // Find references
    private(set) var referenceResults: [SearchFileResult] = []
    private(set) var referenceTitle = ""
    /// Settings ▸ Editor (and Cargo ▸ Format on Save).
    var formatOnSave: Bool { UserDefaults.standard.object(forKey: "formatOnSave") as? Bool ?? true }

    @ObservationIgnored private var lsp: LSPClient?
    @ObservationIgnored private var lspReady = false
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var semanticLegend: SemanticTokenLegend?
    @ObservationIgnored private var runProcess: Process?
    @ObservationIgnored private var watcher: DirectoryWatcher?

    var currentFile: URL? { activeDocument?.url }
    var isRustFile: Bool { activeDocument?.isRust ?? false }
    var canGoBack: Bool { !backStack.isEmpty }
    var dirtyDocuments: [Document] { documents.filter(\.isDirty) }

    func diagnostics(for document: Document) -> [Diagnostic] {
        diagnostics[Self.key(for: document.url)] ?? []
    }

    /// Path relative to the project root (or the full path outside it).
    func displayPath(_ path: String) -> String {
        guard let rootURL else { return path }
        let root = Self.key(for: rootURL) + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    var allProblems: [ProblemItem] {
        diagnostics.keys.sorted().flatMap { path in
            diagnostics[path, default: []].map { ProblemItem(path: path, diagnostic: $0) }
        }
    }

    // MARK: - Folder

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Go module or workspace folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openFolder(url) }
    }

    /// `RustIDE <folder> [file…]` opens the folder, then any listed files as tabs.
    func handleLaunchArguments() async {
        guard !Self.handledLaunchArguments else { return }  // only the first window
        Self.handledLaunchArguments = true
        var folder: URL?
        var files: [URL] = []
        var args = CommandLine.arguments.dropFirst()[...]
        while let arg = args.popFirst() {
            if arg.hasPrefix("--") { _ = args.popFirst(); continue }  // --flag value
            var isDir: ObjCBool = false
            let url = URL(fileURLWithPath: arg).canonicalFileURL
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folder = folder ?? url } else { files.append(url) }
        }
        if folder == nil, files.isEmpty, SessionStore.reopenLastProject,
           CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot") }) == false {
            folder = SessionStore.recentProjects.first
        }
        guard let folder else { return }
        await openFolder(folder, openDefaultFile: files.isEmpty)
        for file in files { openFile(file) }
    }

    func openFolder(_ url: URL, openDefaultFile: Bool = true) async {
        if !dirtyDocuments.isEmpty {
            guard resolveUnsaved(dirtyDocuments) else { return }
        }
        for document in documents { sendDidClose(document) }
        await stopLanguageServer()
        // Use the real path (e.g. /private/tmp, not /tmp) so it matches what rust-analyzer reports.
        let url = url.canonicalFileURL
        rootURL = url
        fileTree = FileNode.loadTree(at: url)
        startWatching(url)
        gitBranch = nil
        gitStatuses = [:]
        gitBases = [:]
        documents = []
        activeDocument = nil
        diagnostics = [:]
        output = ""
        backStack = []
        searchResults = []
        SessionStore.noteOpened(url)
        cargoMetadata = nil
        loadEnabledFeatures()
        await loadRunConfigurations()
        if openDefaultFile {
            restoreSession(in: url)
        }
        refreshGit()
        await startLanguageServer(root: url)
    }

    // MARK: - Run configurations

    @ObservationIgnored private var loadingRunConfigurations = false

    /// Saved configurations for this folder, or one per binary / example Cargo reports.
    func loadRunConfigurations() async {
        guard let rootURL else { return }
        await refreshCargoMetadata()
        guard self.rootURL == rootURL else { return }  // folder changed meanwhile
        loadingRunConfigurations = true
        defer { loadingRunConfigurations = false }
        if let saved = SessionStore.runConfigurations(for: rootURL), !saved.configs.isEmpty {
            runConfigurations = saved.configs
            selectedRunConfigurationID = saved.selected ?? saved.configs.first?.id
        } else {
            runConfigurations = runTargets.map(RunConfiguration.init(target:))
            selectedRunConfigurationID = runConfigurations.first?.id
        }
    }

    /// Re-reads `cargo metadata` (off the main thread).
    func refreshCargoMetadata() async {
        guard let rootURL else { return }
        let root = rootURL
        let (metadata, locked) = await Task.detached(priority: .userInitiated) {
            let metadata = CargoMetadata.load(root: root)
            return (metadata, metadata.map { CargoLock.load(workspaceRoot: $0.workspaceRoot) } ?? [:])
        }.value
        guard self.rootURL == root else { return }
        cargoMetadata = metadata
        lockedVersions = locked
        if let metadata {  // drop features that no longer exist
            let known = Set(metadata.packages.flatMap { package in package.features.map(package.featureKey) })
            if !enabledFeatures.isSubset(of: known) { enabledFeatures.formIntersection(known) }
        }
    }

    // MARK: - Runnables (gutter ▶ from rust-analyzer)

    /// `experimental/runnables` for a file: main functions, tests, test modules, doctests, benches.
    func runnables(in document: Document) async -> [Runnable] {
        guard lspReady, document.usesLanguageServer, let lsp else { return [] }
        let result = try? await lsp.request("experimental/runnables", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
        ])
        return result.map(Runnable.parseAll) ?? []
    }

    /// Runs a runnable: tests go to the Tests panel, the rest (`cargo run`, `cargo bench`) to Output.
    func run(_ runnable: Runnable) {
        if runnable.isTest {
            runTests(.runnable(runnable))
        } else {
            runCargo(runnable.commandLine(extra: featureArguments(packages: Self.selectedPackages(in: runnable.cargoArgs))))
        }
    }

    // MARK: - Dependencies & features (Cargo sidebar)

    /// Crate name → versions in Cargo.lock.
    private(set) var lockedVersions: [String: [String]] = [:]

    /// `package/feature` keys turned on for rust-analyzer and for build / check / test commands.
    var enabledFeatures: Set<String> = [] {
        didSet {
            guard enabledFeatures != oldValue else { return }
            if let rootURL, self !== Self.placeholder {
                UserDefaults.standard.set(enabledFeatures.sorted(), forKey: Self.featuresKey(for: rootURL))
            }
            pushSettings()
        }
    }

    private static func featuresKey(for root: URL) -> String { "cargoFeatures:" + root.path }

    private func loadEnabledFeatures() {
        guard let rootURL else { return }
        enabledFeatures = Set(UserDefaults.standard.stringArray(forKey: Self.featuresKey(for: rootURL)) ?? [])
    }

    /// rust-analyzer settings for this project.
    var serverSettings: JSONValue { RustAnalyzerSettings.current(features: enabledFeatures.sorted()) }

    func isFeatureEnabled(_ feature: String, in package: CargoPackage) -> Bool {
        enabledFeatures.contains(package.featureKey(feature))
    }

    func setFeature(_ feature: String, in package: CargoPackage, enabled: Bool) {
        if enabled { enabledFeatures.insert(package.featureKey(feature)) } else { enabledFeatures.remove(package.featureKey(feature)) }
    }

    /// `--features a/x,b/y` for a command on `packages` (nil = the whole workspace).
    func featureArguments(packages: [String]? = nil) -> [String] {
        let selected = enabledFeatures.filter { key in
            packages.map { names in names.contains { key.hasPrefix($0 + "/") } } ?? true
        }
        return selected.isEmpty ? [] : ["--features", selected.sorted().joined(separator: ",")]
    }

    /// Package names after `-p` flags in `arguments` (nil if none: the whole workspace).
    static func selectedPackages(in arguments: [String]) -> [String]? {
        let names = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-p" || $0.0 == "--package" }.map(\.1)
        return names.isEmpty ? nil : names
    }

    /// `cargo check` / `clippy` / `build` for the workspace with the enabled features.
    func runCargoWithFeatures(_ arguments: [String]) {
        runCargo(arguments + featureArguments(packages: Self.selectedPackages(in: arguments)))
    }

    func addDependency(_ spec: String, kind: CargoDependency.Kind, to package: CargoPackage) {
        let words = spec.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        runCargo(["add"] + words + (kind.flag.map { [$0] } ?? []) + ["-p", package.name])
    }

    func removeDependency(_ dependency: CargoDependency, from package: CargoPackage) {
        var arguments = ["remove", dependency.rename ?? dependency.name, "-p", package.name]
        if let flag = dependency.kind.flag { arguments.append(flag) }
        if let target = dependency.target { arguments += ["--target", target] }
        runCargo(arguments)
    }

    func updateDependency(_ dependency: CargoDependency) {
        runCargo(["update", "-p", dependency.name])
    }

    func openManifest(of package: CargoPackage) {
        openFile(URL(fileURLWithPath: package.manifestPath))
    }

    private func saveRunConfigurations() {
        guard !loadingRunConfigurations, let rootURL, self !== Self.placeholder else { return }
        SessionStore.saveRunConfigurations(runConfigurations, selected: selectedRunConfigurationID, for: rootURL)
    }

    /// ⌘R: `cargo run <target flags> -- <args>` with the configuration's environment.
    func runSelectedConfiguration() {
        guard let config = selectedRunConfiguration else { return runCargo(["run"]) }
        runCargo(config.cargoRunArguments, environment: config.environmentVariables)
    }

    /// ⌘B: builds what Run would run (else the whole workspace).
    func buildProject() {
        guard let config = selectedRunConfiguration else { return runCargoWithFeatures(["build", "--workspace"]) }
        runCargo(["build"] + config.cargoTargetArguments)
    }

    // MARK: - Session

    @ObservationIgnored private var restoringSession = false

    /// Reopens the tabs open last time in this folder (else main.go or the first Go file).
    private func restoreSession(in folder: URL) {
        let saved = SessionStore.session(for: folder)
        let files = (saved?.openFiles ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        restoringSession = true
        defer { restoringSession = false }
        if files.isEmpty {
            if let file = Self.defaultFile(in: fileTree) { openFile(file) }
        } else {
            files.forEach { openFile($0) }
            if let active = saved?.activeFile, let document = documents.first(where: { $0.url.path == active }) {
                activeDocument = document
            }
        }
        saveSession()
    }

    /// Remembers open tabs for this folder (called as tabs open, close or switch).
    func saveSession() {
        guard !restoringSession, let rootURL, self !== Self.placeholder else { return }
        SessionStore.save(SessionStore.Session(openFiles: documents.map(\.url.path),
                                               activeFile: activeDocument?.url.path), for: rootURL)
    }

    func reloadTree() {
        guard let rootURL else { return }
        fileTree = FileNode.loadTree(at: rootURL)
    }

    // MARK: - File system

    private func startWatching(_ root: URL) {
        watcher?.stop()
        watcher = DirectoryWatcher(url: root) { paths in
            Task { @MainActor in self.handleFileSystemChanges(paths) }
        }
    }

    /// Reacts to files changed on disk (by us, an external editor, git, build scripts…).
    func handleFileSystemChanges(_ paths: [String]) {
        // Commits, checkouts, staging… only touch .git: refresh Git state for those too.
        if paths.contains(where: { $0.contains("/.git/") || $0.hasSuffix("/.git") }) { refreshGit() }
        let relevant = paths.filter { !isIgnored(path: $0) }
        guard !relevant.isEmpty else { return }
        if relevant.contains(where: { $0.hasSuffix("/Cargo.toml") || $0.hasSuffix("/Cargo.lock") })
            || relevant.contains(where: { $0.contains("/src/bin/") || $0.contains("/examples/") }) {
            Task { await refreshCargoMetadata() }  // targets, dependencies or locked versions may have changed
        }
        reloadTree()
        notifyWatchedFiles(relevant)
        for document in documents { syncWithDisk(document) }
        refreshGit()
    }

    // MARK: - Git

    /// Re-reads branch, file statuses and HEAD contents of open files (debounced, off the main thread).
    func refreshGit() {
        gitTask?.cancel()
        guard let rootURL else { return }
        let files = documents.map(\.url)
        gitTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached(priority: .utility) {
                () -> (URL, String?, [String: GitFileStatus], [String: String], [GitChange])? in
                guard let top = Git.topLevel(of: rootURL) else { return nil }
                var bases: [String: String] = [:]
                for url in files {
                    if let contents = Git.headContents(of: url, topLevel: top) { bases[url.canonicalFileURL.path] = contents }
                }
                return (top, Git.currentBranch(in: top), Git.status(in: top), bases, Git.changes(in: top))
            }.value
            guard !Task.isCancelled else { return }
            gitTopLevel = snapshot?.0
            gitBranch = snapshot?.1
            gitStatuses = snapshot?.2 ?? [:]
            gitBases = snapshot?.3 ?? [:]
            gitChanges = snapshot?.4 ?? []
        }
    }

    func gitStatus(for url: URL) -> GitFileStatus? {
        gitStatuses[Self.key(for: url)]
    }

    /// Whether a folder contains changed files.
    func gitHasChanges(under directory: URL) -> Bool {
        let prefix = Self.key(for: directory) + "/"
        return gitStatuses.keys.contains { $0.hasPrefix(prefix) }
    }

    func gitBase(for document: Document) -> String? {
        gitBases[Self.key(for: document.url)]
    }

    // MARK: Source control

    func stage(_ changes: [GitChange]) async { await gitMutation { Git.stage(changes.map(\.path), in: $0) } }
    func unstage(_ changes: [GitChange]) async { await gitMutation { Git.unstage(changes.map(\.path), in: $0) } }

    /// Discards work-tree changes (untracked files go to the Trash). The UI confirms first.
    func discard(_ changes: [GitChange]) async {
        for change in changes where change.isUntracked {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: change.path), resultingItemURL: nil)
        }
        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        if !tracked.isEmpty { await gitMutation { Git.discard(tracked, in: $0) } } else { refreshGit() }
    }

    /// Commits staged changes (or everything, if nothing is staged and `stageAll`).
    @discardableResult
    func commit(stageAll: Bool = false) async -> Bool {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            gitError = "Enter a commit message."
            return false
        }
        saveAll()
        if stageAll { await gitMutation { Git.stage(["."], in: $0) } }
        await gitMutation { Git.commit(message: message, in: $0) }
        guard gitError == nil else { return false }
        commitMessage = ""
        flashStatus("Committed: \(message.split(separator: "\n").first ?? "")")
        return true
    }

    private func gitMutation(_ operation: @escaping @Sendable (URL) -> String?) async {
        guard let top = gitTopLevel else { return }
        gitError = await Task.detached(priority: .userInitiated) { operation(top) }.value
        refreshGit()
        // Stay in sync right away for the UI (refreshGit is debounced).
        let changes = await Task.detached { Git.changes(in: top) }.value
        gitChanges = changes
    }

    /// Blame for a zero-based line of the document's current buffer.
    func blame(in document: Document, line: Int) async -> BlameLine? {
        guard let top = gitTopLevel, gitBase(for: document) != nil else { return nil }  // tracked files only
        let url = document.url, text = document.text
        return await Task.detached(priority: .utility) {
            Git.blame(file: url, line: line, contents: text, topLevel: top)
        }.value
    }

    /// Hidden files and build/VCS folders inside the project don't matter to us.
    private func isIgnored(path: String) -> Bool {
        guard let rootURL else { return true }
        let root = Self.key(for: rootURL) + "/"
        guard path.hasPrefix(root) else { return true }
        return path.dropFirst(root.count).split(separator: "/").contains {
            $0.hasPrefix(".") || FileNode.ignoredNames.contains(String($0))
        }
    }

    private func syncWithDisk(_ document: Document) {
        // Deleted or unreadable: keep the buffer; saving recreates the file.
        guard let disk = try? String(contentsOf: document.url, encoding: .utf8) else { return }
        guard disk != document.text else {
            document.hasExternalChange = false
            return
        }
        if document.isDirty {
            document.hasExternalChange = true
        } else {
            reloadFromDisk(document, contents: disk)
        }
    }

    func reloadFromDisk(_ document: Document, contents: String? = nil) {
        guard let disk = contents ?? (try? String(contentsOf: document.url, encoding: .utf8)) else { return }
        replaceText(of: document, with: disk)
        document.isDirty = false
        document.hasExternalChange = false
    }

    func keepLocalVersion(_ document: Document) {
        document.hasExternalChange = false
    }

    private func notifyWatchedFiles(_ paths: [String]) {
        guard lspReady else { return }
        let rustFiles = paths.filter {
            $0.hasSuffix(".rs") || $0.hasSuffix("/Cargo.toml") || $0.hasSuffix("/Cargo.lock")
                || $0.hasSuffix("/rust-toolchain.toml") || $0.hasSuffix("/rust-toolchain")
        }
        let changes: [JSONValue] = rustFiles.map { path in
            let exists = FileManager.default.fileExists(atPath: path)
            return ["uri": .string(URL(fileURLWithPath: path).absoluteString), "type": .int(exists ? 2 : 3)]
        }
        guard !changes.isEmpty else { return }
        try? lsp?.notify("workspace/didChangeWatchedFiles", params: ["changes": .array(changes)])
    }

    // MARK: - File operations

    @discardableResult
    func createFile(named name: String, in directory: URL) throws -> URL {
        let url = try newItemURL(named: name, in: directory)
        let contents = ""
        try contents.write(to: url, atomically: true, encoding: .utf8)
        reloadTree()
        openFile(url)
        return url
    }

    @discardableResult
    func createFolder(named name: String, in directory: URL) throws -> URL {
        let url = try newItemURL(named: name, in: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reloadTree()
        return url
    }

    @discardableResult
    func renameItem(at url: URL, to newName: String) throws -> URL {
        let oldKey = Self.key(for: url)
        let target = try newItemURL(named: newName, in: url.deletingLastPathComponent())
        try FileManager.default.moveItem(at: url, to: target)
        let newKey = Self.key(for: target)
        for document in documents {
            let key = Self.key(for: document.url)
            guard key == oldKey || key.hasPrefix(oldKey + "/") else { continue }
            sendDidClose(document)
            document.move(to: URL(fileURLWithPath: newKey + key.dropFirst(oldKey.count)))
            sendDidOpen(document)
        }
        dropDiagnostics(under: oldKey)
        reloadTree()
        return target
    }

    /// Moves a file or folder to the Trash, closing (and discarding) any open documents inside it.
    func trashItem(at url: URL) throws {
        let key = Self.key(for: url)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        remove(documents.filter {
            let docKey = Self.key(for: $0.url)
            return docKey == key || docKey.hasPrefix(key + "/")
        })
        dropDiagnostics(under: key)
        reloadTree()
    }

    private func newItemURL(named name: String, in directory: URL) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileOperationError.invalidName(name)
        }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists(name) }
        return url
    }

    private func dropDiagnostics(under key: String) {
        for path in diagnostics.keys where path == key || path.hasPrefix(key + "/") {
            diagnostics.removeValue(forKey: path)
        }
    }

    // MARK: - Documents

    /// Opens `url` in a tab (or switches to its existing tab).
    @discardableResult
    func openFile(_ url: URL) -> Document? {
        let url = url.canonicalFileURL
        let key = Self.key(for: url)
        if let existing = documents.first(where: { Self.key(for: $0.url) == key }) {
            activeDocument = existing
            return existing
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            appendOutput("Cannot open \(url.path) (not UTF-8 text?)\n")
            bottomTab = .output
            return nil
        }
        let document = Document(url: url, text: contents, isReadOnly: isOutsideProject(url) || Document.isExpansion(url))
        let insertIndex = activeDocument.flatMap { active in documents.firstIndex { $0 === active } }
            .map { $0 + 1 } ?? documents.count
        documents.insert(document, at: insertIndex)
        activeDocument = document
        saveSession()
        sendDidOpen(document)
        refreshGit()  // fetch its HEAD version for change bars
        return document
    }

    func activate(_ document: Document) {
        activeDocument = document
    }

    func selectAdjacentTab(_ delta: Int) {
        guard let active = activeDocument, let index = documents.firstIndex(where: { $0 === active }),
              documents.count > 1 else { return }
        activeDocument = documents[(index + delta + documents.count) % documents.count]
    }

    func closeDocument(_ document: Document) {
        if document.isDirty, !resolveUnsaved([document]) { return }
        remove([document])
    }

    func closeOtherDocuments(than keep: Document) {
        let others = documents.filter { $0 !== keep }
        let dirty = others.filter(\.isDirty)
        if !dirty.isEmpty, !resolveUnsaved(dirty) { return }
        remove(others)
        activeDocument = keep
    }

    func closeAllDocuments() {
        if !dirtyDocuments.isEmpty, !resolveUnsaved(dirtyDocuments) { return }
        remove(documents)
    }

    private func remove(_ toClose: [Document]) {
        for document in toClose {
            sendDidClose(document)
            guard let index = documents.firstIndex(where: { $0 === document }) else { continue }
            documents.remove(at: index)
            if activeDocument === document {
                activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
            }
        }
        saveSession()
    }

    /// Asks what to do with unsaved documents. Returns false if the user cancelled.
    func resolveUnsaved(_ dirty: [Document]) -> Bool {
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Do you want to save the changes you made to \(dirty[0].name)?"
            : "You have unsaved changes in \(dirty.count) files."
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            dirty.forEach(save)
            return dirty.allSatisfy { !$0.isDirty }
        case .alertThirdButtonReturn:
            for document in dirty {
                document.isDirty = false  // discard: the buffer is about to be closed
            }
            return true
        default:
            return false
        }
    }

    func updateText(of document: Document, to newText: String) {
        guard newText != document.text else { return }
        document.text = newText
        document.isDirty = true
        document.version += 1
        sendDidChange(document)
    }

    /// Changes a document's text programmatically (format, rename, reload…).
    /// The editor applies it as a single undoable edit and keeps the caret in place.
    func replaceText(of document: Document, with newText: String) {
        updateText(of: document, to: newText)
    }

    /// The edits in `edit` that target `document`.
    func edits(for document: Document, in edit: WorkspaceEdit) -> [TextEdit] {
        let key = Self.key(for: document.url)
        return edit.changes.filter { uri, _ in URL(string: uri).map(Self.key(for:)) == key }.flatMap(\.value)
    }

    // MARK: - Formatting

    /// Formats with rust-analyzer (rustfmt, honoring rustfmt.toml).
    func format(_ document: Document) async {
        guard lspReady, document.usesLanguageServer, !document.isReadOnly, let lsp else { return }
        let version = document.version
        guard let result = try? await lsp.request("textDocument/formatting", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
            "options": ["tabSize": 4, "insertSpaces": true],
        ]), document.version == version else { return }  // edited meanwhile: skip
        let edits = result.arrayValue?.compactMap(TextEdit.parse) ?? []
        replaceText(of: document, with: TextEdit.apply(edits, to: document.text))
    }

    func formatActiveDocument() async {
        if let activeDocument { await format(activeDocument) }
    }

    /// ⌘S: format (if enabled), then save.
    func saveFormatted(_ document: Document) async {
        if formatOnSave { await format(document) }
        save(document)
    }

    func saveActiveFormatted() async {
        if let activeDocument { await saveFormatted(activeDocument) }
    }

    func saveAllFormatted() async {
        for document in dirtyDocuments { await saveFormatted(document) }
    }

    func save() {
        if let activeDocument { save(activeDocument) }
    }

    func saveAll() {
        dirtyDocuments.forEach(save)
    }

    func save(_ document: Document) {
        guard !document.isReadOnly else { return }
        do {
            try document.text.write(to: document.url, atomically: true, encoding: .utf8)
            document.isDirty = false
            refreshGit()
            if lspReady, document.usesLanguageServer {
                try? lsp?.notify("textDocument/didSave", params: [
                    "textDocument": ["uri": .string(document.url.absoluteString)],
                ])
            }
        } catch {
            appendOutput("Save failed: \(error.localizedDescription)\n")
            bottomTab = .output
        }
    }

    func reveal(_ problem: ProblemItem) {
        navigate(to: URL(fileURLWithPath: problem.path), position: problem.diagnostic.start)
    }

    // MARK: - Language features

    func completions(in document: Document, at offset: Int) async -> [CompletionItem] {
        // Built-in snippets for the word being typed (not after "." — that's a member).
        let ns = document.text as NSString
        let start = GoIdentifier.prefixStart(in: ns, before: offset)
        let prefix = ns.substring(with: NSRange(location: start, length: offset - start))
        let afterDot = start > 0 && ns.character(at: start - 1) == 0x2E
        let snippets = document.isRust && !afterDot ? RustSnippets.completions(matching: prefix) : []
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/completion", params: params)
        else { return snippets }
        return CompletionItem.parseList(result) + snippets
    }

    func hover(in document: Document, at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/hover", params: params)
        else { return nil }
        return HoverContent.parse(result).map { String($0.prefix(4000)) }
    }

    /// Semantic tokens for the whole document (decoded with the server's legend).
    func semanticTokens(in document: Document) async -> [SemanticToken] {
        guard lspReady, document.usesLanguageServer, let lsp, let legend = semanticLegend,
              let result = try? await lsp.request("textDocument/semanticTokens/full", params: [
                  "textDocument": ["uri": .string(document.url.absoluteString)],
              ])
        else { return [] }
        return legend.decode(result)
    }

    func foldingRanges(in document: Document) async -> [FoldRegion] {
        guard lspReady, document.usesLanguageServer, let lsp,
              let result = try? await lsp.request("textDocument/foldingRange", params: [
                  "textDocument": ["uri": .string(document.url.absoluteString)],
              ])
        else { return [] }
        return FoldRegion.parseAll(result)
    }

    /// Inlay hints for the whole document.
    func inlayHints(in document: Document) async -> [InlayHint] {
        guard lspReady, document.usesLanguageServer, let lsp else { return [] }
        let lines = LineIndex(document.text).lineCount
        guard let result = try? await lsp.request("textDocument/inlayHint", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
            "range": ["start": TextPosition(line: 0, character: 0).json, "end": TextPosition(line: lines, character: 0).json],
        ]) else { return [] }
        return InlayHint.parseAll(result)
    }

    func documentHighlights(in document: Document, at offset: Int) async -> [DocumentHighlight] {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/documentHighlight", params: params)
        else { return [] }
        return DocumentHighlight.parseAll(result)
    }

    func signatureHelp(in document: Document, at offset: Int) async -> SignatureHelp? {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/signatureHelp", params: params)
        else { return nil }
        return SignatureHelp.parse(result)
    }

    /// Interfaces → implementing types (and methods → implementations): jump if one, list if several.
    func jumpToImplementation(from document: Document, at offset: Int) async {
        await jumpToLocations(method: "textDocument/implementation", what: "implementation",
                              from: document, at: offset)
    }

    /// A value's type declaration.
    func jumpToTypeDefinition(from document: Document, at offset: Int) async {
        await jumpToLocations(method: "textDocument/typeDefinition", what: "type definition",
                              from: document, at: offset)
    }

    /// Navigate ▸ Expand Macro: the macro call at `offset`, expanded recursively, in a read-only tab.
    func expandMacro(in document: Document, at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(document, at: offset) else { return }
        guard let result = try? await lsp.request("rust-analyzer/expandMacro", params: params),
              let expansion = MacroExpansion(json: result) else {
            flashStatus("No macro at the cursor")
            return
        }
        let url = Document.expansionDirectory.appendingPathComponent(expansion.fileName)
        do {
            try FileManager.default.createDirectory(at: Document.expansionDirectory, withIntermediateDirectories: true)
            try expansion.documentText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            flashStatus("Expand macro failed: \(error.localizedDescription)")
            return
        }
        let key = Self.key(for: url)
        if let existing = documents.first(where: { Self.key(for: $0.url) == key }) {
            existing.text = expansion.documentText  // re-expanded: refresh the open tab
            existing.version += 1
        }
        openFile(url)
    }

    private func jumpToLocations(method: String, what: String, from document: Document, at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(document, at: offset) else { return }
        let symbol = GoIdentifier.wordRange(in: document.text as NSString, at: offset)
            .map { (document.text as NSString).substring(with: $0) } ?? "symbol"
        let locations = (try? await lsp.request(method, params: params)).map(Location.parseAll) ?? []
        guard !locations.isEmpty else {
            flashStatus("No \(what) found for ‘\(symbol)’")
            return
        }
        if locations.count == 1, let target = URL(string: locations[0].uri), target.isFileURL {
            backStack.append(NavigationPoint(url: document.url, position: LineIndex(document.text).position(of: offset)))
            navigate(to: URL(fileURLWithPath: target.path), position: locations[0].start)
            return
        }
        showLocations(locations, title: "\(locations.count) \(what)s of ‘\(symbol)’")
    }

    /// Lists locations in the References panel.
    private func showLocations(_ locations: [Location], title: String) {
        referenceResults = ProjectSearch.results(for: locations) { path in
            let key = Self.key(for: URL(fileURLWithPath: path))
            return documents.first { Self.key(for: $0.url) == key }?.text
                ?? (try? String(contentsOfFile: path, encoding: .utf8))
        }
        referenceTitle = title
        bottomTab = .references
    }

    func findReferences(in document: Document, at offset: Int) async {
        guard case let (lsp, .object(params))? = positionRequest(document, at: offset) else { return }
        var request = params
        request["context"] = ["includeDeclaration": true]
        let symbol = GoIdentifier.wordRange(in: document.text as NSString, at: offset)
            .map { (document.text as NSString).substring(with: $0) } ?? "symbol"
        guard let result = try? await lsp.request("textDocument/references", params: .object(request)) else {
            flashStatus("Find References failed")
            return
        }
        referenceResults = ProjectSearch.results(for: Location.parseAll(result)) { path in
            let key = Self.key(for: URL(fileURLWithPath: path))
            return documents.first { Self.key(for: $0.url) == key }?.text
                ?? (try? String(contentsOfFile: path, encoding: .utf8))
        }
        let count = referenceResults.reduce(0) { $0 + $1.matches.count }
        referenceTitle = "\(count) reference\(count == 1 ? "" : "s") to ‘\(symbol)’"
        bottomTab = .references
    }

    // MARK: - Rename & workspace edits

    /// The current name if the symbol at `offset` can be renamed, else nil.
    func prepareRename(in document: Document, at offset: Int) async -> String? {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/prepareRename", params: params),
              !result.isNull
        else { return nil }
        if let placeholder = result["placeholder"]?.stringValue { return placeholder }
        // A bare Range (or {range}): read the name from the buffer.
        let range = result["range"] ?? result
        guard let start = TextPosition(json: range["start"]), let end = TextPosition(json: range["end"]) else { return nil }
        return (document.text as NSString).substring(with: LineIndex(document.text).range(from: start, to: end))
    }

    /// Renames the symbol at `offset` across the workspace. Returns an error message, or nil.
    @discardableResult
    func renameSymbol(in document: Document, at offset: Int, to newName: String) async -> String? {
        guard case let (lsp, .object(params))? = positionRequest(document, at: offset) else {
            return "gopls is not ready"
        }
        var request = params
        request["newName"] = .string(newName)
        let versions = Dictionary(documents.map { ($0.id, $0.version) }, uniquingKeysWith: { $1 })
        let result: JSONValue
        do {
            result = try await lsp.request("textDocument/rename", params: .object(request))
        } catch {
            return error.localizedDescription
        }
        // Edits are relative to what gopls saw; bail out if a buffer changed meanwhile.
        guard documents.allSatisfy({ versions[$0.id] == nil || versions[$0.id] == $0.version }) else {
            return "The file changed while renaming; try again."
        }
        let changed = apply(WorkspaceEdit.parse(result))
        flashStatus("Renamed to ‘\(newName)’ in \(changed) file\(changed == 1 ? "" : "s")")
        return nil
    }

    /// Asks for a new name, then renames (⌃⌘E / context menu).
    func promptRename(in document: Document, at offset: Int) async {
        guard let current = await prepareRename(in: document, at: offset) else {
            flashStatus("Nothing to rename here")
            return
        }
        guard let newName = Prompt.text(title: "Rename ‘\(current)’", message: "All references are updated.",
                                        initial: current, confirm: "Rename"),
              newName != current else { return }
        if let error = await renameSymbol(in: document, at: offset, to: newName) {
            let alert = NSAlert()
            alert.messageText = "Couldn't rename ‘\(current)’"
            alert.informativeText = error
            alert.runModal()
        }
    }

    // MARK: - Open Quickly & outline

    func showQuickOpen() {
        guard rootURL != nil else { return }
        quickOpenFiles = nil  // re-list: files may have changed
        quickOpenQuery = ""
        isQuickOpenVisible = true
        updateQuickOpen()
    }

    func hideQuickOpen() {
        quickOpenTask?.cancel()
        isQuickOpenVisible = false
    }

    /// Files now (fuzzy, file name weighted), then gopls workspace symbols merged in.
    func updateQuickOpen() {
        quickOpenTask?.cancel()
        guard let rootURL else { return }
        let query = quickOpenQuery.trimmingCharacters(in: .whitespaces)
        if quickOpenFiles == nil { quickOpenFiles = ProjectSearch.files(under: rootURL) }
        let files = fileItems(matching: query)
        quickOpenItems = files
        guard query.count >= 2, lspReady, let lsp else { return }
        quickOpenTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let result = try? await lsp.request("workspace/symbol", params: ["query": .string(query)]),
                  !Task.isCancelled, query == quickOpenQuery.trimmingCharacters(in: .whitespaces)
            else { return }
            let symbols = SymbolNode.parseAll(result).prefix(200).compactMap { symbol -> QuickOpenItem? in
                guard let uri = symbol.uri, let url = URL(string: uri), url.isFileURL,
                      let score = FuzzyMatch.score(query, symbol.name) else { return nil }
                return QuickOpenItem(
                    title: symbol.name,
                    subtitle: [symbol.detail, displayPath(url.path)].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " — "),
                    icon: SymbolStyle.icon(for: symbol.kind), url: url, position: symbol.position,
                    score: score + 5)  // a symbol named exactly like the query beats a file
            }
            quickOpenItems = (files + symbols).sorted { $0.score > $1.score }.prefix(60).map { $0 }
        }
    }

    private func fileItems(matching query: String) -> [QuickOpenItem] {
        if query.isEmpty {  // open tabs first
            return documents.reversed().map {
                QuickOpenItem(title: $0.name, subtitle: displayPath($0.url.deletingLastPathComponent().path),
                              icon: "doc.text", url: $0.url, position: nil, score: 0)
            }
        }
        return (quickOpenFiles ?? []).compactMap { path -> QuickOpenItem? in
            let relative = displayPath(path)
            guard let score = FuzzyMatch.scorePath(query, relative) else { return nil }
            return QuickOpenItem(title: (relative as NSString).lastPathComponent,
                                 subtitle: (relative as NSString).deletingLastPathComponent,
                                 icon: "doc.text", url: URL(fileURLWithPath: path), position: nil, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(60).map { $0 }
    }

    func open(_ item: QuickOpenItem) {
        hideQuickOpen()
        if let position = item.position {
            navigate(to: item.url, position: position)
        } else {
            openFile(item.url)
        }
    }

    /// Re-reads the active document's symbols (debounced by the caller).
    func refreshOutline() async {
        guard let document = activeDocument, document.usesLanguageServer, lspReady, let lsp,
              let result = try? await lsp.request("textDocument/documentSymbol", params: [
                  "textDocument": ["uri": .string(document.url.absoluteString)],
              ]),
              document === activeDocument
        else {
            if activeDocument?.isRust != true { outline = [] }
            return
        }
        outline = SymbolNode.parseAll(result)
    }

    func reveal(_ symbol: SymbolNode) {
        guard let document = activeDocument else { return }
        document.revealTarget = RevealTarget(position: symbol.position)
    }

    // MARK: - Code actions

    func requestQuickFix() {
        quickFixRequest += 1
    }

    /// Quick fixes, refactorings and source actions at the caret (or selection).
    func codeActions(in document: Document, at offset: Int, length: Int = 0) async -> [CodeAction] {
        guard lspReady, document.usesLanguageServer, let lsp else { return [] }
        let index = LineIndex(document.text)
        let caret = index.position(of: offset)
        let related = diagnostics(for: document).filter { $0.contains(caret) || $0.start.line == caret.line }
        let range: (start: TextPosition, end: TextPosition) = length > 0
            ? (caret, index.position(of: offset + length))
            : related.first.map { ($0.start, $0.end) } ?? (caret, caret)
        guard let result = try? await lsp.request("textDocument/codeAction", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
            "range": ["start": range.start.json, "end": range.end.json],
            "context": ["diagnostics": .array(related.compactMap(\.raw)), "triggerKind": 1],
        ]) else { return [] }
        return CodeAction.parseAll(result)
    }

    /// Runs a code action: resolves it if needed, applies its edit, then runs its command
    /// (gopls may answer with workspace/applyEdit or window/showDocument).
    func perform(_ action: CodeAction) async {
        guard let lsp else { return }
        var action = action
        if action.edit == nil, action.command == nil, action.raw["data"] != nil,
           let resolved = try? await lsp.request("codeAction/resolve", params: action.raw),
           let parsed = CodeAction.parseAll(.array([resolved])).first {
            action = parsed
        }
        if let edit = action.edit { apply(edit) }
        if let command = action.command, let name = command["command"]?.stringValue {
            do {
                _ = try await lsp.request("workspace/executeCommand", params: [
                    "command": .string(name), "arguments": command["arguments"] ?? [],
                ])
            } catch {
                flashStatus("\(action.title) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Requests rust-analyzer sends to us.
    private func handleServerRequest(method: String, params: JSONValue) -> JSONValue? {
        switch method {
        case "workspace/configuration":
            // Same settings as initializationOptions, with the user's current choices.
            let items = params["items"]?.arrayValue ?? []
            return .array(items.map { $0["section"]?.stringValue == "rust-analyzer" ? serverSettings : .null })
        case "workspace/applyEdit":
            apply(WorkspaceEdit.parse(params["edit"] ?? .null))
            return ["applied": true]
        case "window/showDocument":
            guard let uri = params["uri"]?.stringValue, let url = URL(string: uri) else { return ["success": false] }
            if url.isFileURL, params["external"]?.boolValue != true {
                let start = TextPosition(json: params["selection"]?["start"]) ?? TextPosition(line: 0, character: 0)
                navigate(to: url, position: start)
            } else {
                NSWorkspace.shared.open(url)
            }
            return ["success": true]
        default:
            return nil
        }
    }

    /// Applies a WorkspaceEdit: open documents change in their buffers (undoable, unsaved);
    /// other files are rewritten on disk. Returns the number of files changed.
    @discardableResult
    func apply(_ edit: WorkspaceEdit) -> Int {
        var changed = 0
        var written: [String] = []
        var created: [URL] = []
        for uri in edit.creates {
            guard let url = URL(string: uri), url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: url.path, contents: Data()) { created.append(url) }
        }
        for (uri, edits) in edit.changes where !edits.isEmpty {
            guard let url = URL(string: uri), url.isFileURL else { continue }
            let key = Self.key(for: url)
            if let document = documents.first(where: { Self.key(for: $0.url) == key }) {
                replaceText(of: document, with: TextEdit.apply(edits, to: document.text))
                changed += 1
            } else if let disk = try? String(contentsOf: url, encoding: .utf8) {
                do {
                    try TextEdit.apply(edits, to: disk).write(to: url, atomically: true, encoding: .utf8)
                    written.append(url.path)
                    changed += 1
                } catch {
                    appendOutput("Couldn't update \(url.path): \(error.localizedDescription)\n")
                }
            }
        }
        notifyWatchedFiles(written)  // don't wait for FSEvents
        if !created.isEmpty {
            reloadTree()
            created.forEach { openFile($0) }  // e.g. a generated _test.go
        }
        return changed
    }

    // MARK: - Call hierarchy

    func showCallHierarchy(in document: Document, at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(document, at: offset),
              let result = try? await lsp.request("textDocument/prepareCallHierarchy", params: params),
              let item = CallHierarchyItem.parseAll(result).first
        else {
            flashStatus("No function here")
            return
        }
        let root = CallNode(item: item)
        callRoot = root
        bottomTab = .calls
        await expand(root)
    }

    func setCallDirection(_ direction: CallDirection) async {
        guard direction != callDirection else { return }
        callDirection = direction
        guard let root = callRoot else { return }
        let fresh = CallNode(item: root.item)
        callRoot = fresh
        await expand(fresh)
    }

    /// Loads the callers (incoming) or callees (outgoing) of a node.
    func expand(_ node: CallNode) async {
        node.isExpanded = true
        guard node.children == nil, let lsp else { return }
        let method = callDirection == .incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
        guard let result = try? await lsp.request(method, params: ["item": node.item.raw]) else {
            node.children = []
            return
        }
        node.children = CallHierarchyCall.parseAll(result).map { call in
            // Incoming: sites are in the caller's file. Outgoing: in this node's file.
            let uri = callDirection == .incoming ? call.item.uri : node.item.uri
            return CallNode(item: call.item, callSite: call.callSites.first.map { (uri, $0) })
        }
    }

    /// Jumps to the call site if known, else to the function itself.
    func open(_ node: CallNode) {
        if let site = node.callSite, let url = URL(string: site.uri) {
            navigate(to: URL(fileURLWithPath: url.path), position: site.position)
        } else if let url = URL(string: node.item.uri) {
            navigate(to: URL(fileURLWithPath: url.path), position: node.item.position)
        }
    }

    func jumpToDefinition(from document: Document, at offset: Int) async {
        guard case let (lsp, params)? = positionRequest(document, at: offset) else { return }
        let origin = LineIndex(document.text).position(of: offset)
        let result = try? await lsp.request("textDocument/definition", params: params)
        guard let location = result.map(Location.parseAll)?.first,
              let target = URL(string: location.uri), target.isFileURL
        else {
            flashStatus("No definition found")
            return
        }
        backStack.append(NavigationPoint(url: document.url, position: origin))
        if backStack.count > 100 { backStack.removeFirst() }
        navigate(to: URL(fileURLWithPath: target.path), position: location.start)
    }

    func goBack() {
        guard let point = backStack.popLast() else { return }
        navigate(to: point.url, position: point.position)
    }

    func navigate(to url: URL, position: TextPosition, selectingLength length: Int = 0) {
        guard let document = openFile(url) else { return }
        document.revealTarget = RevealTarget(position: position, length: length)
    }

    // MARK: - Find in project

    func showSearch() {
        sidebarMode = .search
        searchFocusRequest += 1
    }

    var searchMatchCount: Int { searchResults.reduce(0) { $0 + $1.matches.count } }

    /// Debounced search, for typing in the search field.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    func performSearch() async {
        let query = searchQuery
        guard let root = rootURL, !query.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        let options = searchOptions
        // Unsaved buffers are searched instead of their files on disk.
        let overrides = Dictionary(dirtyDocuments.map { (Self.key(for: $0.url), $0.text) }, uniquingKeysWith: { $1 })
        isSearching = true
        let (results, error) = await Task.detached(priority: .userInitiated) { () -> ([SearchFileResult], String?) in
            do {
                return (try ProjectSearch.search(root: root, query: query, options: options, overrides: overrides), nil)
            } catch {
                return ([], error.localizedDescription)
            }
        }.value
        guard query == searchQuery, options == searchOptions else { return }  // superseded
        searchResults = results
        searchError = error
        isSearching = false
    }

    /// The regex and template for replacing, if the current query is valid.
    var replacePattern: (regex: NSRegularExpression, template: String)? {
        guard !searchQuery.isEmpty, let regex = try? ProjectSearch.makeRegex(searchQuery, options: searchOptions) else { return nil }
        return (regex, ProjectSearch.template(for: replaceQuery, options: searchOptions))
    }

    /// Replaces every match in the search results' files, re-matching current contents (not stale results).
    /// Open files change in their buffers (undoable); others are rewritten on disk.
    @discardableResult
    func replaceAllInProject() async -> Int {
        guard let (regex, template) = replacePattern else { return 0 }
        var total = 0, files = 0
        var written: [String] = []
        for file in searchResults {
            let key = Self.key(for: URL(fileURLWithPath: file.path))
            if let document = documents.first(where: { Self.key(for: $0.url) == key }) {
                guard !document.isReadOnly else { continue }
                let (text, count) = ProjectSearch.replaceAll(in: document.text, regex: regex, template: template)
                guard count > 0 else { continue }
                replaceText(of: document, with: text)
                total += count
                files += 1
            } else if let disk = try? String(contentsOfFile: file.path, encoding: .utf8) {
                let (text, count) = ProjectSearch.replaceAll(in: disk, regex: regex, template: template)
                guard count > 0 else { continue }
                do {
                    try text.write(toFile: file.path, atomically: true, encoding: .utf8)
                    written.append(file.path)
                    total += count
                    files += 1
                } catch {
                    appendOutput("Couldn't write \(file.path): \(error.localizedDescription)\n")
                }
            }
        }
        notifyWatchedFiles(written)
        flashStatus("Replaced \(total) occurrence\(total == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")")
        await performSearch()
        return total
    }

    /// Replaces one match (if it's still where the results say).
    func replace(_ match: SearchMatch, in file: SearchFileResult) async {
        guard let (regex, template) = replacePattern else { return }
        let url = URL(fileURLWithPath: file.path)
        let key = Self.key(for: url)
        let position = TextPosition(line: match.line, character: match.column)
        if let document = documents.first(where: { Self.key(for: $0.url) == key }) {
            let location = LineIndex(document.text).offset(of: position)
            if let text = ProjectSearch.replaceMatch(in: document.text, at: location, regex: regex, template: template) {
                replaceText(of: document, with: text)
            }
        } else if let disk = try? String(contentsOfFile: file.path, encoding: .utf8) {
            let location = LineIndex(disk).offset(of: position)
            if let text = ProjectSearch.replaceMatch(in: disk, at: location, regex: regex, template: template) {
                try? text.write(toFile: file.path, atomically: true, encoding: .utf8)
                notifyWatchedFiles([file.path])
            }
        }
        await performSearch()
    }

    func open(_ match: SearchMatch, in file: SearchFileResult) {
        navigate(to: URL(fileURLWithPath: file.path),
                 position: TextPosition(line: match.line, character: match.column),
                 selectingLength: match.length)
    }

    private func positionRequest(_ document: Document, at offset: Int) -> (LSPClient, JSONValue)? {
        guard lspReady, document.usesLanguageServer, let lsp else { return nil }
        let position = LineIndex(document.text).position(of: offset)
        return (lsp, ["textDocument": ["uri": .string(document.url.absoluteString)], "position": position.json])
    }

    private func flashStatus(_ message: String) {
        let previous = lspStatus
        lspStatus = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if lspStatus == message { lspStatus = previous }
        }
    }

    // MARK: - rust-analyzer

    func restartLanguageServer() async {
        guard let rootURL else { return }
        await stopLanguageServer()
        await startLanguageServer(root: rootURL)
    }

    private func startLanguageServer(root: URL) async {
        guard let server = ToolLocator.find("rust-analyzer") else {
            lspStatus = "rust-analyzer not found — rustup component add rust-analyzer"
            return
        }
        let client = LSPClient()
        client.onNotification = { method, params in
            Task { @MainActor in self.handleNotification(client, method: method, params: params) }
        }
        client.onRequest = { method, params in
            await MainActor.run { self.handleServerRequest(method: method, params: params) }
        }
        client.onExit = { status in
            Task { @MainActor in
                guard self.lsp === client else { return }
                self.lsp = nil
                self.lspReady = false
                // rustup's proxy exits at once when the component isn't installed.
                self.lspStatus = self.lspReady || status == 0
                    ? "rust-analyzer exited (status \(status))"
                    : "rust-analyzer exited — try: rustup component add rust-analyzer"
            }
        }

        do {
            try client.start(executable: server, environment: ToolLocator.environment(), currentDirectory: root)
            lsp = client
            lspStatus = "rust-analyzer: starting…"
            let initialized = try await client.request("initialize", params: Self.initializeParams(root: root, settings: serverSettings))
            guard lsp === client else { return }  // folder changed while initializing
            semanticLegend = SemanticTokenLegend(initializeResult: initialized)
            try client.notify("initialized", params: [:])
            lspReady = true
            observeSettings()
            lspStatus = "rust-analyzer: indexing…"
            languageServerEpoch += 1
            documents.forEach(sendDidOpen)
        } catch {
            if lsp === client { lsp = nil }
            lspStatus = "rust-analyzer failed: \(error.localizedDescription)"
        }
    }

    /// Settings ▸ Editor / Cargo ▸ Clippy on Save: rust-analyzer re-reads its configuration
    /// (workspace/configuration) after didChangeConfiguration.
    private func observeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .rustAnalyzerSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSettings() }
        }
    }

    func pushSettings() {
        guard lspReady else { return }
        try? lsp?.notify("workspace/didChangeConfiguration", params: ["settings": serverSettings])
    }

    private func stopLanguageServer() async {
        guard let client = lsp else { return }
        lsp = nil
        lspReady = false
        client.onNotification = nil
        client.onExit = nil
        client.onRequest = nil
        lspStatus = "rust-analyzer: stopped"
        await client.shutdown()
    }

    private func handleNotification(_ client: LSPClient, method: String, params: JSONValue) {
        guard lsp === client else { return }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let published = Diagnostic.parsePublish(params), let url = URL(string: published.uri) else { return }
            let key = Self.key(for: url)
            if published.diagnostics.isEmpty {
                diagnostics.removeValue(forKey: key)
            } else {
                diagnostics[key] = published.diagnostics
            }
        case "window/showMessage":
            if let message = params["message"]?.stringValue { lspStatus = "rust-analyzer: \(message)" }
        case "experimental/serverStatus":
            // rust-analyzer: quiescent = done loading the Cargo workspace and indexing.
            let health = params["health"]?.stringValue ?? "ok"
            let quiescent = params["quiescent"]?.boolValue ?? false
            let message = params["message"]?.stringValue.map { " — \($0.split(separator: "\n").first ?? "")" } ?? ""
            switch (health, quiescent) {
            case ("ok", true): lspStatus = "rust-analyzer: ready"
            case ("ok", false): lspStatus = "rust-analyzer: indexing…"
            default: lspStatus = "rust-analyzer: \(health)\(message)"
            }
            if quiescent { languageServerEpoch += 1 }  // re-request hints/tokens once fully loaded
        default:
            break
        }
    }

    private func sendDidOpen(_ document: Document) {
        guard lspReady, document.usesLanguageServer else { return }
        try? lsp?.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": .string(document.url.absoluteString),
                "languageId": "rust",
                "version": .int(document.version),
                "text": .string(document.text),
            ],
        ])
    }

    private func sendDidChange(_ document: Document) {
        guard lspReady, document.usesLanguageServer else { return }
        try? lsp?.notify("textDocument/didChange", params: [
            "textDocument": ["uri": .string(document.url.absoluteString), "version": .int(document.version)],
            "contentChanges": [["text": .string(document.text)]],
        ])
    }

    private func sendDidClose(_ document: Document) {
        guard lspReady, document.usesLanguageServer else { return }
        try? lsp?.notify("textDocument/didClose", params: [
            "textDocument": ["uri": .string(document.url.absoluteString)],
        ])
    }

    private static func initializeParams(root: URL, settings: JSONValue) -> JSONValue {
        let textDocument: JSONValue = [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "publishDiagnostics": ["relatedInformation": false],
            "completion": [
                "completionItem": ["snippetSupport": true, "documentationFormat": ["markdown", "plaintext"]],
            ],
            "hover": ["contentFormat": ["markdown", "plaintext"]],
            "signatureHelp": ["signatureInformation": [
                "documentationFormat": ["plaintext", "markdown"],
                "parameterInformation": ["labelOffsetSupport": true],
                "activeParameterSupport": true,
            ]],
            "definition": ["linkSupport": false],
            "implementation": ["linkSupport": false],
            "typeDefinition": ["linkSupport": false],
            "documentHighlight": ["dynamicRegistration": false],
            "callHierarchy": ["dynamicRegistration": false],
            "inlayHint": ["dynamicRegistration": false],
            "foldingRange": ["lineFoldingOnly": false],
            "semanticTokens": [
                "requests": ["full": true, "range": false],
                "formats": ["relative"],
                "tokenTypes": .array(SemanticTokenLegend.clientTypes.map(JSONValue.string)),
                "tokenModifiers": .array(SemanticTokenLegend.clientModifiers.map(JSONValue.string)),
                "multilineTokenSupport": false,
                "overlappingTokenSupport": false,
            ],
            "rename": ["prepareSupport": true],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
            "codeAction": [
                "isPreferredSupport": true,
                "dataSupport": true,
                "resolveSupport": ["properties": ["edit"]],
                "codeActionLiteralSupport": ["codeActionKind": ["valueSet": [
                    "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite",
                    "source", "source.organizeImports", "source.fixAll",
                ]]],
            ],
            "formatting": ["dynamicRegistration": false],
        ]
        let workspace: JSONValue = [
            "applyEdit": true,
            "workspaceEdit": ["documentChanges": true, "resourceOperations": ["create"]],
            "configuration": true,
            "workspaceFolders": true,
            "didChangeWatchedFiles": ["dynamicRegistration": false],
        ]
        return [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "RustIDE", "version": "0.1.0"],
            "rootUri": .string(root.absoluteString),
            "initializationOptions": settings,
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": [
                "textDocument": textDocument,
                "workspace": workspace,
                "general": ["positionEncodings": ["utf-16"]],
                "window": ["showDocument": ["support": true], "workDoneProgress": true],
                "experimental": ["serverStatusNotification": true],
            ],
        ]
    }

    // MARK: - Tests

    /// Coverage from the last "Test with Coverage" run (cargo-llvm-cov; see ROADMAP 2.5).
    private(set) var coverage: CoverageReport?
    var showCoverage = true

    /// Zero-based line → covered, for the editor tint (empty when hidden or not measured).
    func coverageLines(for document: Document) -> [Int: Bool] {
        guard showCoverage, let coverage else { return [:] }
        return coverage.files[Self.key(for: document.url)]?.lines ?? [:]
    }

    /// cargo-llvm-cov (`cargo install cargo-llvm-cov`) is on PATH or in ~/.cargo/bin.
    var canMeasureCoverage: Bool { ToolLocator.find("cargo-llvm-cov") != nil }

    /// Cargo ▸ Test with Coverage: all tests under `cargo llvm-cov`, then line coverage in the editor.
    func runTestsWithCoverage(_ scope: TestScope = .all) {
        guard canMeasureCoverage else {
            output = "Test coverage uses cargo-llvm-cov. Install it with:\n\n"
                + "    rustup component add llvm-tools-preview\n    cargo install cargo-llvm-cov\n"
            bottomTab = .output
            return
        }
        runTests(scope, coverage: true)
    }

    func clearCoverage() {
        coverage = nil
    }

    /// Runs `cargo test` for a scope and streams libtest's results into `testReport`.
    func runTests(_ scope: TestScope, coverage measure: Bool = false) {
        guard let rootURL, !isRunning else { return }
        guard let cargo = ToolLocator.find("cargo") else {
            output = "cargo not found. Install Rust from https://rustup.rs\n"
            bottomTab = .output
            return
        }
        saveAll()
        var arguments = ["test"]
        switch scope {
        case .all:
            arguments.append("--workspace")
            testRunTitle = "All tests"
        case .package(let url):
            if let package = cargoMetadata?.package(containing: Self.key(for: url)) {
                arguments += ["-p", package.name]
                testRunTitle = "Package \(package.name)"
            } else {
                testRunTitle = "All tests"
            }
        case .test(let path, let file):
            if let metadata = cargoMetadata {
                arguments += RustTestFinder.targetArguments(forFile: Self.key(for: file), in: metadata)
            }
            arguments += ["--", path, "--exact"]
            testRunTitle = path
        case .runnable(let runnable):
            arguments = runnable.commandLine()
            testRunTitle = runnable.label
        }
        let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
        arguments.insert(contentsOf: featureArguments(packages: Self.selectedPackages(in: arguments)), at: separator)
        // `cargo llvm-cov` takes cargo test's arguments; it writes LCOV and passes the test output through.
        let lcov = FileManager.default.temporaryDirectory.appendingPathComponent("rustide-cov-\(UUID().uuidString).lcov")
        if measure, arguments.first == "test" {
            arguments.replaceSubrange(0..<1, with: ["llvm-cov", "--lcov", "--output-path", lcov.path])
            testRunTitle += " (coverage)"
        }
        lastTestScope = scope
        testReport = CargoTestReport()
        selectedTestID = nil
        output = "$ cargo \(arguments.joined(separator: " "))\n"
        bottomTab = .tests
        isRunning = true

        let process = Process()
        process.executableURL = cargo
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        process.environment = ToolLocator.environment().merging(["CARGO_TERM_COLOR": "never"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let lines = data.isEmpty ? buffer.flush() : buffer.append(data)
            if data.isEmpty { handle.readabilityHandler = nil }
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach { self.consumeTestLine($0) } }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))  // let the last lines land
                self.isRunning = false
                self.runProcess = nil
                let r = self.testReport
                self.appendOutput("\n[\(r.passed) passed, \(r.failed) failed, \(r.skipped) ignored — exit \(status)]\n")
                if r.tests.isEmpty, status != 0 { self.bottomTab = .output }  // build failed
                self.selectedTestID = self.selectedTestID ?? r.tests.first { $0.status == .failed }?.id
                if measure, let text = try? String(contentsOf: lcov, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: lcov)
                    self.coverage = CoverageReport.parseLCOV(text, root: rootURL.path)
                    self.showCoverage = true
                    if let coverage = self.coverage {
                        self.appendOutput(String(format: "[line coverage %.1f%% in %d files]\n", coverage.percent, coverage.files.count))
                    }
                }
            }
        }
        do {
            try process.run()
            runProcess = process
        } catch {
            isRunning = false
            appendOutput("Failed to start cargo: \(error.localizedDescription)\n")
        }
    }

    private func consumeTestLine(_ line: String) {
        testReport.consume(line: line)
        appendOutput(line + "\n")
    }

    /// Module path of a file in its crate (`net::http`), the prefix of its tests' full names.
    func testModulePath(for document: Document) -> String {
        let path = Self.key(for: document.url)
        let packageRoot = cargoMetadata?.package(containing: path).map { ($0.manifestPath as NSString).deletingLastPathComponent }
            ?? rootURL.map(Self.key(for:)) ?? ""
        return RustTestFinder.modulePath(ofFile: path, packageRoot: packageRoot)
    }

    /// The full name (`tests::adds`) of the #[test] around the caret, if any.
    private func testAtCaret(in document: Document) -> String? {
        guard document.usesLanguageServer,
              let test = RustTestFinder.enclosingTest(in: document.text, at: document.caretOffset) else { return nil }
        return RustTestFinder.join(testModulePath(for: document), test.path)
    }

    /// Runs the #[test] around the caret, else the active file's package.
    func runTestAtCaret() {
        guard let document = activeDocument else { return runTests(.all) }
        if let name = testAtCaret(in: document) {
            runTests(.test(name, in: document.url))
        } else {
            runTests(.package(document.url))
        }
    }

    func runActivePackageTests() {
        guard let document = activeDocument else { return runTests(.all) }
        runTests(.package(document.url))
    }

    /// Re-runs one test from the Tests panel (located by name in the project's sources).
    func rerun(_ test: TestResult) {
        if let file = locateTest(named: test.name)?.file {
            runTests(.test(test.name, in: file))
        } else if let lastTestScope {
            runTests(lastTestScope)
        }
    }

    /// Opens a test function's declaration.
    func revealTest(named name: String) {
        guard let found = locateTest(named: name) else { return }
        navigate(to: found.file, position: TextPosition(line: found.line, character: 0))
    }

    /// Finds `#[test] fn` with this full module path among the project's .rs files (open buffers first).
    private func locateTest(named name: String) -> (file: URL, line: Int)? {
        guard let rootURL else { return nil }
        let shortName = name.components(separatedBy: "::").last ?? name
        var fallback: (file: URL, line: Int)?
        for path in ProjectSearch.files(under: rootURL) where path.hasSuffix(".rs") {
            let key = Self.key(for: URL(fileURLWithPath: path))
            let open = documents.first { Self.key(for: $0.url) == key }
            guard let text = open?.text ?? (try? String(contentsOfFile: path, encoding: .utf8)),
                  text.contains(shortName) else { continue }
            let packageRoot = cargoMetadata?.package(containing: key).map { ($0.manifestPath as NSString).deletingLastPathComponent }
                ?? Self.key(for: rootURL)
            let prefix = RustTestFinder.modulePath(ofFile: key, packageRoot: packageRoot)
            for test in RustTestFinder.testFunctions(in: text) {
                if RustTestFinder.join(prefix, test.path) == name { return (URL(fileURLWithPath: path), test.line) }
                if fallback == nil, test.name == shortName { fallback = (URL(fileURLWithPath: path), test.line) }
            }
        }
        return fallback
    }

    /// Opens `file.rs:line[:column]` from build / test output (resolved within the project).
    func revealOutputReference(file: String, line: Int, column: Int? = nil) {
        guard let rootURL else { return }
        let suffix = "/" + (file as NSString).lastPathComponent
        let candidates = ProjectSearch.files(under: rootURL).filter { $0.hasSuffix(suffix) }
        let match = candidates.first { $0.hasSuffix("/" + file) } ?? candidates.first
        guard let path = match else { return }
        navigate(to: URL(fileURLWithPath: path), position: TextPosition(line: max(line - 1, 0), character: max((column ?? 1) - 1, 0)))
    }

    // MARK: - Debugging

    /// Zero-based breakpoint lines for a document (for the gutter).
    func breakpointLines(for document: Document) -> Set<Int> {
        Set((breakpoints[Self.key(for: document.url)] ?? []).map { $0 - 1 })
    }

    /// Zero-based execution line if the debuggee is paused in this document.
    func executionLine(for document: Document) -> Int? {
        guard let location = executionLocation, location.path == Self.key(for: document.url) else { return nil }
        return location.line - 1
    }

    func toggleBreakpoint(in document: Document, line: Int) {
        let key = Self.key(for: document.url)
        var lines = breakpoints[key] ?? []
        if lines.contains(line + 1) {
            lines.remove(line + 1)
            breakpointConditions[key]?[line + 1] = nil
        } else {
            lines.insert(line + 1)
        }
        breakpoints[key] = lines.isEmpty ? nil : lines
        syncBreakpoints(key)
    }

    /// Zero-based lines whose breakpoints have conditions (drawn differently).
    func conditionalBreakpointLines(for document: Document) -> Set<Int> {
        Set((breakpointConditions[Self.key(for: document.url)] ?? [:]).keys.map { $0 - 1 })
    }

    /// Asks for a condition (empty removes it); adds the breakpoint if needed.
    func editBreakpointCondition(in document: Document, line: Int) {
        let key = Self.key(for: document.url)
        let current = breakpointConditions[key]?[line + 1] ?? ""
        guard let condition = Prompt.text(title: "Breakpoint Condition",
                                          message: "Stop at line \(line + 1) only when this expression is true (LLDB syntax, e.g. i == 3).",
                                          initial: current, confirm: "Done", allowEmpty: true) else { return }
        breakpoints[key, default: []].insert(line + 1)
        breakpointConditions[key, default: [:]][line + 1] = condition.isEmpty ? nil : condition
        syncBreakpoints(key)
    }

    func setBreakpointConditionForTesting(_ condition: String, in document: Document, line: Int) {
        let key = Self.key(for: document.url)
        breakpoints[key, default: []].insert(line + 1)
        breakpointConditions[key, default: [:]][line + 1] = condition
    }

    /// Breakpoints for a path with their conditions, as DebugSession wants them.
    private func breakpointSpec(_ key: String) -> [Int: String?] {
        Dictionary(uniqueKeysWithValues: (breakpoints[key] ?? []).map { ($0, breakpointConditions[key]?[$0]) })
    }

    private func syncBreakpoints(_ key: String) {
        guard let session = debugSession, session.isActive else { return }
        let spec = breakpointSpec(key)
        Task { await session.setBreakpoints(path: key, lines: spec) }
    }

    /// Debugger value of the expression at the mouse (nil unless paused).
    func evaluate(_ expression: String) async -> String? {
        await debugSession?.evaluate(expression)
    }

    func toggleBreakpointAtCaret() {
        guard let document = activeDocument, document.usesLanguageServer else { return }
        toggleBreakpoint(in: document, line: LineIndex(document.text).position(of: document.caretOffset).line)
    }

    func clearBreakpoints() {
        let paths = breakpoints.keys
        breakpoints = [:]
        breakpointConditions = [:]
        if let session = debugSession, session.isActive {
            Task { for path in paths { await session.setBreakpoints(path: path, lines: [:]) } }
        }
    }

    /// Debugs the #[test] at the caret, else the selected run configuration (else the default binary).
    func startDebugging() {
        guard rootURL != nil else { return }
        if let document = activeDocument, let name = testAtCaret(in: document) {
            debug(test: name, in: document.url)
        } else if let config = selectedRunConfiguration {
            debug(configuration: config)
        } else {
            launchDebugger(title: rootURL?.lastPathComponent ?? "program", build: ["build"],
                           pick: { $0.last { !$0.isTest } }, arguments: [], environment: [:])
        }
    }

    func debug(configuration config: RunConfiguration) {
        launchDebugger(title: config.name, build: ["build"] + config.cargoTargetArguments,
                       pick: { artifacts in
                           artifacts.last { !$0.isTest && $0.targetName == config.target } ?? artifacts.last { !$0.isTest }
                       },
                       arguments: config.argumentList, environment: config.environmentVariables)
    }

    /// Builds the test binary for `file`'s target and runs just `name` under the debugger.
    func debug(test name: String, in file: URL) {
        var build = ["test", "--no-run"]
        if let metadata = cargoMetadata { build += RustTestFinder.targetArguments(forFile: Self.key(for: file), in: metadata) }
        build += featureArguments(packages: Self.selectedPackages(in: build))
        launchDebugger(title: name, build: build, pick: { $0.last { $0.isTest } },
                       arguments: [name, "--exact", "--nocapture", "--test-threads=1"], environment: [:])
    }

    /// `cargo <build> --message-format=json-render-diagnostics`, then lldb-dap on the executable `pick` chooses.
    private func launchDebugger(title: String, build: [String], pick: @escaping @MainActor ([CargoArtifact]) -> CargoArtifact?,
                                arguments: [String], environment: [String: String]) {
        guard let rootURL, !isRunning else { return }
        if let session = debugSession, session.isActive { return }
        guard let cargo = ToolLocator.find("cargo") else {
            output = "cargo not found. Install Rust from https://rustup.rs\n"
            bottomTab = .output
            return
        }
        saveAll()
        let buildArguments = build + ["--message-format=json-render-diagnostics"]
        output = "Debugging \(title)…\n$ cargo \(build.joined(separator: " "))\n"
        bottomTab = .output
        isRunning = true
        Task {
            let artifacts = await buildArtifacts(cargo: cargo, arguments: buildArguments, in: rootURL)
            isRunning = false
            runProcess = nil
            guard let artifacts else { return appendOutput("\nBuild failed: nothing to debug.\n") }
            guard let program = pick(artifacts) else { return appendOutput("\nNo executable to debug in the build output.\n") }
            let (adapter, sysroot) = await Task.detached { (DAPClient.locateLLDBDAP(), RustLLDB.sysroot()) }.value
            guard let adapter else {
                output += "\nlldb-dap not found. Install Xcode or the Command Line Tools (xcode-select --install), "
                    + "or Homebrew's llvm, or set its path in Settings ▸ Tools.\n"
                return
            }
            startSession(title: title, adapter: adapter, directory: rootURL, launch: [
                "program": .string(program.executable),
                "args": .array(arguments.map(JSONValue.string)),
                "cwd": .string(Self.key(for: rootURL)),
                "env": .array(environment.sorted { $0.key < $1.key }.map { .string("\($0.key)=\($0.value)") }),
                "initCommands": .array(RustLLDB.initCommands(sysroot: sysroot).map(JSONValue.string)),
                "stopOnEntry": false,
            ])
        }
    }

    /// Runs a cargo build with JSON messages: rendered diagnostics stream to Output, artifacts are returned
    /// (nil if the build failed or was stopped).
    private func buildArtifacts(cargo: URL, arguments: [String], in root: URL) async -> [CargoArtifact]? {
        let process = Process()
        process.executableURL = cargo
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ToolLocator.environment().merging(["CARGO_TERM_COLOR": "never"]) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(text) }
        }
        let collected = LineCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            collected.append(data)
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                runProcess = process
            } catch {
                appendOutput("Failed to start cargo: \(error.localizedDescription)\n")
                continuation.resume(returning: -1)
            }
        }
        try? await Task.sleep(for: .milliseconds(80))  // let the last output land
        return status == 0 ? CargoArtifact.executables(in: collected.lines) : nil
    }

    private func startSession(title: String, adapter: URL, directory: URL, launch: JSONValue) {
        let session = DebugSession(title: title)
        session.onLocation = { [weak self] location in
            guard let self else { return }
            executionLocation = location
            if let location, FileManager.default.fileExists(atPath: location.path) {
                navigate(to: URL(fileURLWithPath: location.path), position: TextPosition(line: location.line - 1, character: 0))
            }
        }
        session.onOutput = { [weak self] text in self?.appendOutput(text) }
        debugSession = session
        bottomTab = .debug
        let specs = Dictionary(uniqueKeysWithValues: breakpoints.keys.map { ($0, breakpointSpec($0)) })
        Task { await session.start(adapter: adapter, directory: directory, launch: launch, breakpoints: specs) }
    }

    func stopDebugging() {
        debugSession?.stop()
        executionLocation = nil
    }

    var isDebugging: Bool { debugSession?.isActive ?? false }

    // MARK: - cargo run / build / check

    func runCargo(_ arguments: [String], environment extra: [String: String] = [:]) {
        guard let rootURL, !isRunning else { return }
        guard let cargo = ToolLocator.find("cargo") else {
            output = "cargo not found. Install Rust from https://rustup.rs\n"
            bottomTab = .output
            return
        }
        saveAll()
        let envNote = extra.isEmpty ? "" : extra.keys.sorted().map { "\($0)=… " }.joined()
        // Echo the command shell-style (quote words with spaces) so it reads as it ran.
        let shown = arguments.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
        output = "$ \(envNote)cargo \(shown)\n"
        bottomTab = .output
        isRunning = true

        let process = Process()
        process.executableURL = cargo
        process.arguments = arguments
        process.currentDirectoryURL = rootURL
        // No ANSI escapes in the Output panel; it isn't a terminal.
        process.environment = ToolLocator.environment().merging(["CARGO_TERM_COLOR": "never"]) { $1 }.merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.appendOutput(chunk) }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                // Let any final output chunks land first.
                try? await Task.sleep(for: .milliseconds(50))
                self.isRunning = false
                self.runProcess = nil
                self.appendOutput("\n[process exited with status \(status)]\n")
            }
        }
        do {
            try process.run()
            runProcess = process
        } catch {
            isRunning = false
            appendOutput("Failed to start cargo: \(error.localizedDescription)\n")
        }
    }

    func stopRun() {
        if isDebugging { return stopDebugging() }
        runProcess?.interrupt()
    }

    private func appendOutput(_ s: String) {
        output += s
    }

    // MARK: - Helpers

    static func key(for url: URL) -> String {
        url.canonicalFileURL.path
    }

    /// Files outside the project (stdlib, module cache) open read-only.
    private func isOutsideProject(_ url: URL) -> Bool {
        guard let rootURL else { return false }
        return !Self.key(for: url).hasPrefix(Self.key(for: rootURL) + "/")
    }

    private static func defaultFile(in nodes: [FileNode]) -> URL? {
        let files = nodes.filter { !$0.isDirectory }
        if let src = nodes.first(where: { $0.isDirectory && $0.name == "src" }) {
            let children = src.children ?? []
            if let entry = children.first(where: { $0.name == "main.rs" || $0.name == "lib.rs" }) { return entry.url }
        }
        return (files.first { $0.name == "main.rs" } ?? files.first { $0.url.pathExtension == "rs" }
            ?? files.first { $0.name == "Cargo.toml" })?.url
    }
}

/// Accumulates a byte stream (thread-safe) and splits it into lines at the end.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }

    var lines: [String] {
        lock.withLock { String(decoding: data, as: UTF8.self).components(separatedBy: "\n") }
    }
}

/// Splits a byte stream into lines across reads (used off the main thread).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let complete = pending[pending.startIndex...last]
            pending = Data(pending[pending.index(after: last)...])
            return String(decoding: complete, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    func flush() -> [String] {
        lock.withLock {
            defer { pending = Data() }
            let rest = String(decoding: pending, as: UTF8.self)
            return rest.isEmpty ? [] : [rest]
        }
    }
}
