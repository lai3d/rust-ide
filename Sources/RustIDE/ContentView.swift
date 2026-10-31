import RustIDECore
import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            if workspace.rootURL == nil {
                WelcomeView()
            } else {
                EditorArea()
            }
        }
        .navigationTitle(workspace.rootURL?.lastPathComponent ?? "RustIDE")
        .navigationSubtitle(workspace.gitBranch.map { "⎇ \($0)" } ?? "")
        .overlay(alignment: .top) {
            if workspace.isQuickOpenVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { workspace.hideQuickOpen() }
                    QuickOpenView().padding(.top, 60)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.buildProject() } label: {
                    Label("Build", systemImage: "hammer")
                }
                .help("cargo build (⌘B)")
                Button { workspace.runTests(.all) } label: {
                    Label("Test", systemImage: "checkmark.diamond")
                }
                .help("cargo test (⌘U)")
                RunConfigurationPicker()
                Button { workspace.runSelectedConfiguration() } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .help("Run the selected configuration (⌘R)")
                Button { workspace.startDebugging() } label: {
                    Label("Debug", systemImage: "ladybug")
                }
                .help("Debug with Delve (⌥⌘R)")
                .disabled(workspace.isDebugging)
                Button { workspace.stopRun() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop (⌘.)")
                .disabled(!workspace.isRunning && !workspace.isDebugging)
            }
        }
        .task { await workspace.handleLaunchArguments() }
        .sheet(isPresented: Binding(get: { workspace.isEditingRunConfigurations },
                                    set: { workspace.isEditingRunConfigurations = $0 })) {
            RunConfigurationsSheet().environment(workspace)
        }
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var workspace
    @State private var recents = SessionStore.recentProjects

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("RustIDE").font(.largeTitle.bold())
            Text("Open a Go module folder to get started.")
                .foregroundStyle(.secondary)
            Button("Open Folder…") { workspace.presentOpenPanel() }
                .keyboardShortcut("o")
                .controlSize(.large)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Recent Projects").font(.headline)
                        Spacer()
                        Button("Clear") {
                            SessionStore.clearRecents()
                            recents = []
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.bottom, 4)
                    ForEach(recents.prefix(8), id: \.self) { url in
                        Button { Task { await workspace.openFolder(url) } } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 420)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Sidebar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $workspace.sidebarMode) {
                Image(systemName: "folder").help("Files").tag(SidebarMode.files)
                Image(systemName: "magnifyingglass").help("Find in Project (⇧⌘F)").tag(SidebarMode.search)
                Image(systemName: "list.bullet.indent").help("Outline").tag(SidebarMode.outline)
                Image(systemName: "arrow.triangle.branch").help("Source Control (⌃⇧G)").tag(SidebarMode.git)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch workspace.sidebarMode {
            case .files: FileTreeView()
            case .search: SearchView()
            case .outline: OutlineView()
            case .git: SourceControlView()
            }
        }
    }
}

struct FileTreeView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selection = Binding<URL?>(
            get: { workspace.currentFile },
            set: { if let url = $0 { workspace.openFile(url) } })

        List(workspace.fileTree, children: \.children, selection: selection) { node in
            HStack(spacing: 4) {
                Label(node.name, systemImage: Self.icon(for: node))
                    .lineLimit(1)
                    .foregroundStyle(gitColor(for: node) ?? .primary)
                Spacer(minLength: 0)
                if let status = workspace.gitStatus(for: node.url) {
                    Text(status.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.color(for: status))
                } else if node.isDirectory, workspace.gitHasChanges(under: node.url) {
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                }
            }
            .contextMenu { itemMenu(for: node) }
        }
        .listStyle(.sidebar)
        .contextMenu {
            if let root = workspace.rootURL {
                Button("New File…") { newFile(in: root) }
                Button("New Folder…") { newFolder(in: root) }
                Divider()
                Button("Reload") { workspace.reloadTree() }
            }
        }
    }

    @ViewBuilder
    private func itemMenu(for node: FileNode) -> some View {
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button("New File…") { newFile(in: folder) }
        Button("New Folder…") { newFolder(in: folder) }
        Divider()
        Button("Rename…") { rename(node) }
        Button("Move to Trash") { trash(node) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
    }

    private func newFile(in folder: URL) {
        guard let name = Prompt.text(title: "New File", message: "In \(folder.lastPathComponent)",
                                     initial: "untitled.go", confirm: "Create") else { return }
        Prompt.attempt { try workspace.createFile(named: name, in: folder) }
    }

    private func newFolder(in folder: URL) {
        guard let name = Prompt.text(title: "New Folder", message: "In \(folder.lastPathComponent)",
                                     initial: "", confirm: "Create") else { return }
        Prompt.attempt { try workspace.createFolder(named: name, in: folder) }
    }

    private func rename(_ node: FileNode) {
        guard let name = Prompt.text(title: "Rename “\(node.name)”", initial: node.name, confirm: "Rename"),
              name != node.name else { return }
        Prompt.attempt { try workspace.renameItem(at: node.url, to: name) }
    }

    private func trash(_ node: FileNode) {
        guard Prompt.confirm(title: "Move “\(node.name)” to the Trash?",
                             message: "Open tabs for it are closed without saving.",
                             confirm: "Move to Trash") else { return }
        Prompt.attempt { try workspace.trashItem(at: node.url) }
    }

    private func gitColor(for node: FileNode) -> Color? {
        workspace.gitStatus(for: node.url).map(Self.color(for:))
    }

    static func color(for status: GitFileStatus) -> Color {
        switch status {
        case .modified, .renamed: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        }
    }

    private static func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension {
        case "go": return "doc.text"
        case "mod", "sum": return "shippingbox"
        case "md": return "doc.richtext"
        default: return "doc"
        }
    }
}

struct EditorArea: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                TabBar()
                Divider()
                if let document = workspace.activeDocument, document.hasExternalChange {
                    ExternalChangeBanner(document: document)
                }
                if let document = workspace.activeDocument, workspace.diffDocumentID != document.id {
                    BreadcrumbBar(document: document)
                    Divider()
                }
                ZStack {
                    // Every open document keeps a live editor (undo, scroll, selection);
                    // only the active one is shown.
                    ForEach(workspace.documents) { document in
                        DocumentEditor(document: document, isActive: document === workspace.activeDocument)
                    }
                    if let document = workspace.activeDocument, workspace.diffDocumentID == document.id {
                        DiffView(document: document)
                    }
                    if workspace.documents.isEmpty {
                        Text("Select a file")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(minHeight: 200)

            BottomPanel()
                .frame(minHeight: 100, idealHeight: 180)
        }
    }
}

struct ExternalChangeBanner: View {
    @Environment(Workspace.self) private var workspace
    let document: Document

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("“\(document.name)” changed on disk, and you have unsaved changes.")
                .font(.callout)
            Spacer()
            Button("Reload from Disk") { workspace.reloadFromDisk(document) }
            Button("Keep My Version") { workspace.keepLocalVersion(document) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct DocumentEditor: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = 4
    @AppStorage("inlayHints") private var showInlayHints = true
    @AppStorage("inlineBlame") private var showBlame = true
    let document: Document
    let isActive: Bool

    var body: some View {
        CodeEditorView(
            text: document.text,
            highlightRust: document.isRust,
            testPathPrefix: document.isRust ? workspace.testModulePath(for: document) : nil,
            testStatuses: workspace.testStatuses,
            breakpoints: workspace.breakpointLines(for: document),
            conditionalBreakpoints: workspace.conditionalBreakpointLines(for: document),
            executionLine: workspace.executionLine(for: document),
            coverageLines: workspace.coverageLines(for: document),
            isEditable: !document.isReadOnly,
            isActive: isActive,
            settings: EditorSettings(fontSize: fontSize, tabWidth: tabWidth),
            showInlayHints: showInlayHints,
            languageServerEpoch: workspace.languageServerEpoch,
            gitBase: workspace.gitBase(for: document),
            showBlame: showBlame,
            diagnostics: workspace.diagnostics(for: document),
            reveal: document.revealTarget,
            quickFixRequest: workspace.quickFixRequest,
            foldRequest: workspace.foldRequest,
            editRequest: workspace.editRequest,
            services: EditorServices(
                completions: { await workspace.completions(in: document, at: $0) },
                hover: { await workspace.hover(in: document, at: $0) },
                signatureHelp: { await workspace.signatureHelp(in: document, at: $0) },
                highlights: { await workspace.documentHighlights(in: document, at: $0) },
                inlayHints: { await workspace.inlayHints(in: document) },
                semanticTokens: { await workspace.semanticTokens(in: document) },
                blame: { await workspace.blame(in: document, line: $0) },
                foldingRanges: { await workspace.foldingRanges(in: document) },
                definition: { offset in Task { await workspace.jumpToDefinition(from: document, at: offset) } },
                references: { offset in Task { await workspace.findReferences(in: document, at: offset) } },
                callHierarchy: { offset in Task { await workspace.showCallHierarchy(in: document, at: offset) } },
                implementation: { offset in Task { await workspace.jumpToImplementation(from: document, at: offset) } },
                typeDefinition: { offset in Task { await workspace.jumpToTypeDefinition(from: document, at: offset) } },
                rename: { offset in Task { await workspace.promptRename(in: document, at: offset) } },
                codeActions: { await workspace.codeActions(in: document, at: $0, length: $1) },
                performAction: { action in Task { await workspace.perform(action) } },
                runTest: { name in workspace.runTests(.test(name, in: document.url)) },
                toggleBreakpoint: { line in workspace.toggleBreakpoint(in: document, line: line) },
                editBreakpointCondition: { line in workspace.editBreakpointCondition(in: document, line: line) },
                evaluate: { await workspace.evaluate($0) },
                caretMoved: { document.caretOffset = $0 }),
            onChange: { workspace.updateText(of: document, to: $0) })
    }
}

struct TabBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            Button { workspace.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!workspace.canGoBack)
                .help("Go Back (⌃⌘←)")
                .padding(.horizontal, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.documents) { document in
                            TabItem(document: document,
                                    title: title(for: document),
                                    isActive: document === workspace.activeDocument)
                                .id(document.id)
                        }
                    }
                }
                .onChange(of: workspace.activeDocument?.id) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Spacer(minLength: 0)
            if let document = workspace.activeDocument, workspace.gitBase(for: document) != nil {
                Button {
                    workspace.diffDocumentID = workspace.diffDocumentID == document.id ? nil : document.id
                } label: {
                    Image(systemName: "arrow.left.arrow.right.square")
                        .foregroundStyle(workspace.diffDocumentID == document.id ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Compare with HEAD (⌥⌘D)")
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 30)
    }

    /// Adds the parent folder when two open files share a name.
    private func title(for document: Document) -> String {
        let clash = workspace.documents.contains { $0 !== document && $0.name == document.name }
        guard clash else { return document.name }
        return "\(document.url.deletingLastPathComponent().lastPathComponent)/\(document.name)"
    }
}

struct TabItem: View {
    @Environment(Workspace.self) private var workspace
    let document: Document
    let title: String
    let isActive: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: document.isReadOnly ? "lock.fill" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            ZStack {
                if document.isDirty && !isHovering {
                    Circle().fill(.secondary).frame(width: 7, height: 7)
                } else {
                    Button { workspace.closeDocument(document) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovering || isActive ? 1 : 0)
                    .help("Close Tab (⌘W)")
                }
            }
            .frame(width: 14, height: 14)
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(document) }
        .onHover { isHovering = $0 }
        .help(document.url.path)
        .contextMenu {
            Button("Close Tab") { workspace.closeDocument(document) }
            Button("Close Other Tabs") { workspace.closeOtherDocuments(than: document) }
            Button("Close All Tabs") { workspace.closeAllDocuments() }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
        }
    }
}

struct BottomPanel: View {
    @Environment(Workspace.self) private var workspace

    private var testsLabel: String {
        let report = workspace.testReport
        if report.failed > 0 { return "Tests ✗\(report.failed)" }
        if report.passed > 0 { return "Tests ✓\(report.passed)" }
        return "Tests"
    }

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $workspace.bottomTab) {
                    Text("Problems (\(workspace.allProblems.count))").tag(BottomTab.problems)
                    Text("References").tag(BottomTab.references)
                    Text("Calls").tag(BottomTab.calls)
                    Text(testsLabel).tag(BottomTab.tests)
                    Text("Debug").tag(BottomTab.debug)
                    Text("Terminal").tag(BottomTab.terminal)
                    Text("Output").tag(BottomTab.output)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if workspace.isRunning { ProgressView().controlSize(.small) }
                Text(workspace.lspStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            switch workspace.bottomTab {
            case .problems: ProblemsList()
            case .references: ReferencesList()
            case .calls: CallsPanel()
            case .tests: TestsPanel()
            case .debug: DebugPanel()
            case .terminal: TerminalPanel()
            case .output: OutputView()
            }
        }
    }
}

struct ProblemsList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let problems = workspace.allProblems
        if problems.isEmpty {
            Text("No problems")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(problems) { item in
                Button { workspace.reveal(item) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.diagnostic.severity == .error ? .red : .yellow)
                        Text("\(workspace.displayPath(item.path)):\(item.diagnostic.start.line + 1):\(item.diagnostic.start.character + 1)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.diagnostic.message)
                            .lineLimit(2)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

private struct OutputLine: View {
    @Environment(Workspace.self) private var workspace
    let text: String

    var body: some View {
        if let reference = OutputReferences.find(in: text).first {
            Button { workspace.revealOutputReference(file: reference.file, line: reference.line, column: reference.column) } label: {
                Text(text).underline().foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        } else {
            Text(text.isEmpty ? " " : text)
        }
    }
}

struct ReferencesList: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.referenceResults.isEmpty {
            Text("Right-click a symbol and choose Find References (⇧⌘R).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Text(workspace.referenceTitle).font(.callout.weight(.semibold))
                ForEach(workspace.referenceResults) { file in
                    Section {
                        ForEach(file.matches) { match in
                            Button { workspace.open(match, in: file) } label: { MatchRow(match: match) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        FileHeader(path: workspace.displayPath(file.path), count: file.matches.count)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

struct OutputView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if workspace.output.isEmpty {
                        Text("No output yet. Use Build (⌘B), Test (⌘U) or Run (⌘R).").foregroundStyle(.secondary)
                    }
                    // Line by line, so `file.go:12:3` references from go build/vet/run are clickable.
                    ForEach(Array(workspace.output.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                            id: \.offset) { _, line in
                        OutputLine(text: String(line))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: workspace.output) {
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}
