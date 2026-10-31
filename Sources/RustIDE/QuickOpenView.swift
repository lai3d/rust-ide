import RustIDECore
import SwiftUI

/// SF Symbol names for LSP SymbolKind values.
enum SymbolStyle {
    static func icon(for kind: Int) -> String {
        switch kind {
        case 2, 3, 4: "shippingbox"                 // module, namespace, package
        case 5, 23: "s.square"                      // class, struct
        case 6: "m.square"                          // method
        case 7, 8: "p.square"                       // property, field
        case 9, 12: "f.square"                      // constructor, function
        case 10, 22: "e.square"                     // enum, enum member
        case 11: "i.square"                         // interface
        case 13: "v.square"                         // variable
        case 14: "c.square"                         // constant
        case 26: "t.square"                         // type parameter
        default: "number.square"
        }
    }

    static func color(for kind: Int) -> Color {
        switch kind {
        case 6, 9, 12: .purple
        case 5, 10, 11, 23, 26: .green
        case 7, 8, 13: .blue
        case 14, 22: .orange
        default: .secondary
        }
    }
}

/// ⇧⌘O / ⌘P palette: fuzzy file finder plus workspace symbols.
struct QuickOpenView: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var focused: Bool
    @State private var selection = 0

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open Quickly — files and symbols", text: $workspace.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit(openSelection)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onExitCommand { workspace.hideQuickOpen() }
            }
            .padding(12)
            if !workspace.quickOpenItems.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(workspace.quickOpenItems.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { workspace.open(item) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(360, CGFloat(workspace.quickOpenItems.count) * 27 + 12))
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: workspace.quickOpenQuery) {
            selection = 0
            workspace.updateQuickOpen()
        }
    }

    private func row(_ item: QuickOpenItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(item.position == nil ? .secondary : .primary)
                .frame(width: 18)
            Text(item.title).fontWeight(.medium).lineLimit(1)
            Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !workspace.quickOpenItems.isEmpty else { return }
        selection = min(max(selection + delta, 0), workspace.quickOpenItems.count - 1)
    }

    private func openSelection() {
        guard workspace.quickOpenItems.indices.contains(selection) else { return }
        workspace.open(workspace.quickOpenItems[selection])
    }
}

/// Sidebar outline of the active Go file (textDocument/documentSymbol).
struct OutlineView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if workspace.outline.isEmpty {
                Text(workspace.isGoFile ? "No symbols" : "Open a Go file to see its outline.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(workspace.outline, children: \.children) { symbol in
                    Button { workspace.reveal(symbol) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: SymbolStyle.icon(for: symbol.kind))
                                .foregroundStyle(SymbolStyle.color(for: symbol.kind))
                            Text(symbol.name).lineLimit(1)
                            if let detail = symbol.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        // Refresh when the file or its text changes; the task restarts (debounces) on each change.
        .task(id: "\(workspace.activeDocument?.id.uuidString ?? "")|\(workspace.activeDocument?.text.hashValue ?? 0)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await workspace.refreshOutline()
        }
    }
}
