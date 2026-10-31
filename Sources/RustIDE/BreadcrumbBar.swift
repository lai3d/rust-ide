import RustIDECore
import SwiftUI

/// folder › file › Type › method, following the caret (from the document's outline).
struct BreadcrumbBar: View {
    @Environment(Workspace.self) private var workspace
    let document: Document

    var body: some View {
        let symbols = document.isRust ? SymbolNode.path(in: workspace.outline, at: document.caretPosition) : []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                    Text(folder).foregroundStyle(.secondary)
                    chevron
                }
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(document.name)
                ForEach(symbols) { symbol in
                    chevron
                    Button { workspace.reveal(symbol) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: SymbolStyle.icon(for: symbol.kind))
                                .foregroundStyle(SymbolStyle.color(for: symbol.kind))
                            Text(symbol.name)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
        }
        .frame(height: 22)
        // Keep the outline fresh as the file changes (debounced; restarts on each change).
        .task(id: "\(document.id.uuidString)|\(document.text.hashValue)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await workspace.refreshOutline()
        }
    }

    private var folders: [String] {
        let relative = workspace.displayPath(document.url.deletingLastPathComponent().path)
        guard relative != document.url.deletingLastPathComponent().path else {  // outside the project
            return [document.url.deletingLastPathComponent().lastPathComponent]
        }
        return relative.split(separator: "/").map(String.init)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
    }
}
