import RustIDECore
import SwiftUI

/// Debug controls, call stack and variables.
struct DebugPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let session = workspace.debugSession {
            VStack(spacing: 0) {
                DebugToolbar(session: session)
                Divider()
                HSplitView {
                    CallStackList(session: session)
                        .frame(minWidth: 200, idealWidth: 280)
                    VariablesList(session: session)
                        .frame(minWidth: 240)
                }
            }
        } else {
            VStack(spacing: 8) {
                Text("Click a line number to set a breakpoint, then start debugging.")
                    .foregroundStyle(.secondary)
                Button("Start Debugging (⌥⌘R)") { workspace.startDebugging() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DebugToolbar: View {
    @Environment(Workspace.self) private var workspace
    let session: DebugSession

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout).lineLimit(1)
            Spacer()
            Group {
                if session.state == .running {
                    button("pause.fill", "Pause") { session.pause() }
                } else {
                    button("play.fill", "Continue (⌃⌘Y)") { session.resume() }
                        .disabled(session.state != .stopped)
                }
                button("arrow.turn.down.right", "Step Over (F6)") { session.stepOver() }
                button("arrow.down.to.line", "Step Into (F7)") { session.stepInto() }
                button("arrow.up.to.line", "Step Out (F8)") { session.stepOut() }
            }
            .disabled(session.state == .terminated)
            Divider().frame(height: 16)
            if session.isActive {
                button("stop.fill", "Stop Debugging") { workspace.stopDebugging() }
            } else {
                button("arrow.clockwise", "Debug Again") { workspace.startDebugging() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private var statusColor: Color {
        switch session.state {
        case .starting: .yellow
        case .running: .green
        case .stopped: .orange
        case .terminated: .secondary
        }
    }

    private var statusText: String {
        switch session.state {
        case .starting: "Starting \(session.title)…"
        case .running: "Running \(session.title)"
        case .stopped: "Paused" + (session.stopReason.map { " (\($0))" } ?? "")
        case .terminated: session.errorMessage.map { "Failed: \($0)" } ?? "Finished \(session.title)"
        }
    }
}

private struct CallStackList: View {
    @Environment(Workspace.self) private var workspace
    let session: DebugSession

    var body: some View {
        List(selection: Binding(
            get: { session.selectedFrameID },
            set: { id in if let id { Task { await session.select(frameID: id) } } })
        ) {
            Section("Call Stack") {
                ForEach(session.frames) { frame in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(frame.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        if let path = frame.path {
                            Text("\(workspace.displayPath(path)):\(frame.line)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .tag(frame.id)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct VariablesList: View {
    let session: DebugSession
    @State private var newWatch = ""

    var body: some View {
        List {
            Section("Watch") {
                ForEach(session.watches, id: \.self) { expression in
                    HStack(spacing: 6) {
                        Text(expression).font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(session.watchValues[expression] ?? "…")
                            .font(.system(size: 12, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                        Spacer()
                        Button { session.removeWatch(expression) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField("Add expression…", text: $newWatch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        session.addWatch(newWatch)
                        newWatch = ""
                    }
            }
            Section("Variables") {
                ForEach(session.scopes) { node in
                    VariableRow(node: node, session: session)
                }
                if session.scopes.isEmpty {
                    Text(session.state == .running ? "Running…" : "Not paused")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct VariableRow: View {
    @Bindable var node: VariableNode
    let session: DebugSession

    var body: some View {
        if node.reference > 0 {
            DisclosureGroup(isExpanded: Binding(
                get: { node.isExpanded },
                set: { open in
                    if open { Task { await session.expand(node) } } else { node.isExpanded = false }
                })
            ) {
                ForEach(node.children ?? []) { child in
                    VariableRow(node: child, session: session)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(node.name).font(.system(size: 12, weight: .medium, design: .monospaced))
            if !node.value.isEmpty {
                Text(node.value).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            if let type = node.type, !type.isEmpty {
                Text(type).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(node.value)
    }
}
