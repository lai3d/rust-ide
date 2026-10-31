import AppKit
import RustIDECore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask per window, so each prompt names that project's files.
        for workspace in Workspace.allOpen where !workspace.dirtyDocuments.isEmpty {
            guard workspace.resolveUnsaved(workspace.dirtyDocuments) else { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a dead language server's stdin must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--snapshot") {
            // Debug snapshots render off-screen: never take keyboard focus from the user's app.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Needed when launched as a bare SwiftPM executable (no .app bundle).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        Snapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Workspace.allOpen.forEach { $0.stopDebugging() }  // ends lldb-dap and the debuggees
    }
}

/// The focused window's workspace, for menu commands.
struct FocusedWorkspaceKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[FocusedWorkspaceKey.self] }
        set { self[FocusedWorkspaceKey.self] = newValue }
    }
}

/// One window = one project (its own documents, gopls, debugger).
struct WorkspaceWindow: View {
    @State private var workspace = Workspace()

    var body: some View {
        ContentView()
            .environment(workspace)
            .focusedSceneValue(\.workspace, workspace)
            .frame(minWidth: 900, minHeight: 600)
            .background(WindowCloseGuardView(workspace: workspace))
            .onAppear { Workspace.register(workspace) }
    }
}

@main
struct RustIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // A folder in argv (`RustIDE ~/proj`, IDE Toolbox) must not count as a document to open:
        // otherwise SwiftUI skips the first window when there's no saved window state.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        WindowGroup("RustIDE", id: "workspace") {
            WorkspaceWindow()
        }
        .commands { RustIDECommands() }
        Settings {
            SettingsView().environment(Workspace.current ?? Workspace.placeholder)
        }
    }
}

/// Menu commands; they act on the focused window's workspace.
struct RustIDECommands: Commands {
    @FocusedValue(\.workspace) private var focused: Workspace?
    @Environment(\.openWindow) private var openWindow
    @AppStorage("formatOnSave") private var formatOnSave = true
    @AppStorage(RustAnalyzerSettings.checkCommandKey) private var checkCommand = "check"

    /// Without a focused window, commands target an empty workspace (and are disabled or no-ops).
    private var workspace: Workspace { focused ?? Workspace.placeholder }

    private static func functionKey(_ key: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt32(key))!))
    }

    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "workspace") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Folder…") {
                    if let focused { focused.presentOpenPanel() } else { openWindow(id: "workspace") }
                }
                .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(SessionStore.recentProjects.prefix(10), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            if let focused { Task { await focused.openFolder(url) } }
                        }
                    }
                    Divider()
                    Button("Clear Menu") { SessionStore.clearRecents() }
                }
            }
            CommandGroup(replacing: .printItem) {
                Button("Open Quickly…") { workspace.showQuickOpen() }
                    .keyboardShortcut("p")
                    .disabled(workspace.rootURL == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let document = workspace.activeDocument { workspace.closeDocument(document) }
                }
                .keyboardShortcut("w")
                .disabled(workspace.activeDocument == nil)
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") { Task { await workspace.saveActiveFormatted() } }
                    .keyboardShortcut("s")
                    .disabled(workspace.activeDocument == nil)
                Button("Save All") { Task { await workspace.saveAllFormatted() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Project…") { workspace.showSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Editor") {
                Button("Toggle Comment") { workspace.requestEdit(.toggleComment) }
                    .keyboardShortcut("/", modifiers: .command)
                Divider()
                Button("Shift Right") { workspace.requestEdit(.indent) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Shift Left") { workspace.requestEdit(.outdent) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Move Line Up") { workspace.requestEdit(.moveLinesUp) }
                    .keyboardShortcut("[", modifiers: [.option, .command])
                Button("Move Line Down") { workspace.requestEdit(.moveLinesDown) }
                    .keyboardShortcut("]", modifiers: [.option, .command])
                Button("Duplicate Line") { workspace.requestEdit(.duplicateLines) }
                    .keyboardShortcut("d", modifiers: [.shift, .command])
            }
            CommandMenu("Navigate") {
                Button("Open Quickly…") { workspace.showQuickOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.rootURL == nil)
                Divider()
                Button("Jump to Definition") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.jumpToDefinition(from: document, at: document.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .command])
                .disabled(!workspace.isRustFile)
                Button("Jump to Implementation") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.jumpToImplementation(from: document, at: document.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.option, .command])
                .disabled(!workspace.isRustFile)
                Button("Jump to Type Definition") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.jumpToTypeDefinition(from: document, at: document.caretOffset) }
                }
                .keyboardShortcut("j", modifiers: [.control, .option, .command])
                .disabled(!workspace.isRustFile)
                Button("Find References") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.findReferences(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!workspace.isRustFile)
                Button("Call Hierarchy") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.showCallHierarchy(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("h", modifiers: [.control, .option])
                .disabled(!workspace.isRustFile)
                Button("Expand Macro") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.expandMacro(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("m", modifiers: [.control, .option, .command])
                .disabled(!workspace.isRustFile)
                Button("Go Back") { workspace.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                    .disabled(!workspace.canGoBack)
                Divider()
                Button("Fold") { workspace.requestFold(.fold) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                    .disabled(!workspace.isRustFile)
                Button("Unfold") { workspace.requestFold(.unfold) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                    .disabled(!workspace.isRustFile)
                Button("Fold All") { workspace.requestFold(.foldAll) }
                    .keyboardShortcut(.leftArrow, modifiers: [.shift, .option, .command])
                    .disabled(!workspace.isRustFile)
                Button("Unfold All") { workspace.requestFold(.unfoldAll) }
                    .keyboardShortcut(.rightArrow, modifiers: [.shift, .option, .command])
                    .disabled(!workspace.isRustFile)
                Divider()
                Button("Next Tab") { workspace.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { workspace.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandMenu("Refactor") {
                Button("Rename Symbol…") {
                    guard let document = workspace.activeDocument else { return }
                    Task { await workspace.promptRename(in: document, at: document.caretOffset) }
                }
                .keyboardShortcut("e", modifiers: [.control, .command])
                .disabled(!workspace.isRustFile)
                Button("Quick Fix…") { workspace.requestQuickFix() }
                    .keyboardShortcut(.return, modifiers: .option)
                    .disabled(!workspace.isRustFile)
            }
            CommandMenu("Debug") {
                Button("Start Debugging") { workspace.startDebugging() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(workspace.rootURL == nil || workspace.isDebugging)
                Button("Stop Debugging") { workspace.stopDebugging() }
                    .disabled(!workspace.isDebugging)
                Divider()
                Button("Continue") { workspace.debugSession?.resume() }
                    .keyboardShortcut("y", modifiers: [.control, .command])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Pause") { workspace.debugSession?.pause() }
                    .disabled(workspace.debugSession?.state != .running)
                Button("Step Over") { workspace.debugSession?.stepOver() }
                    .keyboardShortcut(Self.functionKey(NSF6FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Step Into") { workspace.debugSession?.stepInto() }
                    .keyboardShortcut(Self.functionKey(NSF7FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Button("Step Out") { workspace.debugSession?.stepOut() }
                    .keyboardShortcut(Self.functionKey(NSF8FunctionKey), modifiers: [])
                    .disabled(workspace.debugSession?.state != .stopped)
                Divider()
                Button("Toggle Breakpoint") { workspace.toggleBreakpointAtCaret() }
                    .keyboardShortcut("\\", modifiers: .command)
                    .disabled(!workspace.isRustFile)
                Button("Remove All Breakpoints") { workspace.clearBreakpoints() }
                    .disabled(workspace.breakpoints.isEmpty)
            }
            CommandMenu("Git") {
                Button("Source Control") { workspace.sidebarMode = .git }
                    .keyboardShortcut("g", modifiers: [.control, .shift])
                    .disabled(!workspace.isGitRepository)
                Button("Compare with HEAD") {
                    guard let document = workspace.activeDocument else { return }
                    workspace.diffDocumentID = workspace.diffDocumentID == document.id ? nil : document.id
                }
                .keyboardShortcut("d", modifiers: [.option, .command])
                .disabled(workspace.activeDocument.map { workspace.gitBase(for: $0) == nil } ?? true)
            }
            CommandMenu("Cargo") {
                Button("Run") { workspace.runSelectedConfiguration() }
                    .keyboardShortcut("r")
                Button("Edit Run Configurations…") { workspace.isEditingRunConfigurations = true }
                    .disabled(workspace.rootURL == nil)
                Button("Build") { workspace.buildProject() }
                    .keyboardShortcut("b")
                Button("Check (cargo check)") { workspace.runCargoWithFeatures(["check", "--workspace", "--all-targets"]) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Clippy (cargo clippy)") { workspace.runCargoWithFeatures(["clippy", "--workspace", "--all-targets"]) }
                    .keyboardShortcut("v", modifiers: [.control, .option, .command])
                Divider()
                Button("Test All") { workspace.runTests(.all) }
                    .keyboardShortcut("u")
                Button("Test Package") { workspace.runActivePackageTests() }
                    .keyboardShortcut("u", modifiers: [.control, .command])
                Button("Run Test at Cursor") { workspace.runTestAtCaret() }
                    .keyboardShortcut("u", modifiers: [.control, .option, .command])
                Button("Test with Coverage") { workspace.runTestsWithCoverage() }
                    .keyboardShortcut("u", modifiers: [.control, .shift, .command])
                Button(workspace.showCoverage ? "Hide Coverage" : "Show Coverage") { workspace.showCoverage.toggle() }
                    .disabled(workspace.coverage == nil)
                Divider()
                Button("Terminal") { workspace.showTerminal() }
                    .keyboardShortcut("`", modifiers: .control)
                Divider()
                Button("Format Project (cargo fmt)") { workspace.runCargo(["fmt", "--all"]) }
                Button("Build Docs (cargo doc --open)") { workspace.runCargo(["doc", "--no-deps", "--open"]) }
                Button("Clean (cargo clean)") { workspace.runCargo(["clean"]) }
                Menu("Dependencies") {
                    Button("Update (cargo update)") { workspace.runCargo(["update"]) }
                    Button("Fetch (cargo fetch)") { workspace.runCargo(["fetch"]) }
                    Button("Tree (cargo tree)") { workspace.runCargo(["tree"]) }
                    Button("Outdated Lock Check (cargo update --dry-run)") { workspace.runCargo(["update", "--dry-run"]) }
                }
                .disabled(workspace.rootURL == nil)
                Divider()
                Button("Stop") { workspace.stopRun() }
                    .keyboardShortcut(".")
                Divider()
                Button("Format Document") { Task { await workspace.formatActiveDocument() } }
                    .keyboardShortcut("f", modifiers: [.option, .shift])
                    .disabled(!workspace.isRustFile)
                Toggle("Format on Save", isOn: $formatOnSave)
                Toggle("Clippy on Save", isOn: Binding(
                    get: { checkCommand == "clippy" },
                    set: {
                        checkCommand = $0 ? "clippy" : "check"
                        NotificationCenter.default.post(name: .rustAnalyzerSettingsChanged, object: nil)
                    }))
                Divider()
                Button("Restart rust-analyzer") { Task { await workspace.restartLanguageServer() } }
            }
            }
}
