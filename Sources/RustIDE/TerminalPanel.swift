import AppKit
import RustIDECore
import SwiftTerm
import SwiftUI

/// A shell running in a PTY, rendered by SwiftTerm. Owned by the workspace so it survives
/// switching bottom-panel tabs.
@MainActor
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    @ObservationIgnored let view: LocalProcessTerminalView
    private(set) var hasExited = false
    private(set) var title = "Terminal"
    @ObservationIgnored private let directory: URL

    init(directory: URL) {
        self.directory = directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        super.init()
        view.processDelegate = self
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        start()
    }

    func start() {
        hasExited = false
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ToolLocator.environment()  // PATH includes go, gopls, dlv
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "RustIDE"
        view.startProcess(executable: shell, args: ["-l"],
                          environment: environment.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent,  // login shell
                          currentDirectory: directory.path)
    }

    func send(_ text: String) {
        view.send(data: ArraySlice(Array(text.utf8)))
    }

    func terminate() {
        if !hasExited { view.terminate() }
    }

    // LocalProcessTerminalViewDelegate (SwiftTerm calls these on the main thread).
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { self.title = title.isEmpty ? "Terminal" : title }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { self.hasExited = true }
    }
}

struct TerminalPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let session = workspace.terminal {
            ZStack(alignment: .top) {
                TerminalHost(session: session)
                    .padding(.leading, 6)
                if session.hasExited {
                    HStack {
                        Text("The shell exited.").foregroundStyle(.secondary)
                        Button("Restart Shell") { session.start() }
                    }
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            Button("Open Terminal (⌃`)") { workspace.showTerminal() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view.removeFromSuperview()  // re-attach the same live view
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: ()) {}
}
