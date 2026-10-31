import RustIDECore
import SwiftUI

/// Incoming/outgoing call tree for a function (⌃⌥H).
struct CallsPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let root = workspace.callRoot {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: SymbolStyle.icon(for: root.item.kind))
                        .foregroundStyle(SymbolStyle.color(for: root.item.kind))
                    Text(root.item.name).font(.system(.body, design: .monospaced).weight(.semibold))
                    Spacer()
                    Picker("Direction", selection: Binding(
                        get: { workspace.callDirection },
                        set: { direction in Task { await workspace.setCallDirection(direction) } })
                    ) {
                        Text("Callers").tag(CallDirection.incoming)
                        Text("Callees").tag(CallDirection.outgoing)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
                List {
                    if let children = root.children, children.isEmpty {
                        Text(workspace.callDirection == .incoming ? "No callers" : "No calls")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(root.children ?? []) { node in
                        CallRow(node: node)
                    }
                }
                .listStyle(.plain)
            }
        } else {
            Text("Put the caret on a function and choose Navigate ▸ Call Hierarchy (⌃⌥H).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CallRow: View {
    @Environment(Workspace.self) private var workspace
    let node: CallNode

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { node.isExpanded },
            set: { open in
                if open { Task { await workspace.expand(node) } } else { node.isExpanded = false }
            })
        ) {
            ForEach(node.children ?? []) { child in
                CallRow(node: child)
            }
        } label: {
            Button { workspace.open(node) } label: {
                HStack(spacing: 6) {
                    Image(systemName: SymbolStyle.icon(for: node.item.kind))
                        .foregroundStyle(SymbolStyle.color(for: node.item.kind))
                    Text(node.item.name).font(.system(size: 12, design: .monospaced))
                    if let detail = node.item.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let site = node.callSite, let url = URL(string: site.uri) {
                        Text("\(shortPath(url.path)):\(site.position.line + 1)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Project-relative path, or just `pkg/file.go` for the standard library and module cache.
    private func shortPath(_ path: String) -> String {
        let display = workspace.displayPath(path)
        guard display == path else { return display }
        return path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}
