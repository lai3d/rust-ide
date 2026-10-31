import RustIDECore
import SwiftUI

/// Side-by-side diff of a document against HEAD (Git ▸ Compare with HEAD).
struct DiffView: View {
    @Environment(Workspace.self) private var workspace
    let document: Document

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("HEAD", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading)
                Label("Working copy", systemImage: "pencil").frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { workspace.diffDocumentID = nil }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if let base = workspace.gitBase(for: document) {
                let rows = SideBySideDiff.rows(base: base, current: document.text)
                if rows.count == 1, case .gap = rows[0].kind {
                    Text("No changes since HEAD.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        // Two equal columns filling the width; long lines truncate.
                        let width = max(260, (geometry.size.width - 1) / 2)
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in DiffRowView(row: row, document: document, columnWidth: width) }
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Text("This file isn't tracked by Git (or the folder isn't a repository).")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffRowView: View {
    @Environment(Workspace.self) private var workspace
    let row: DiffRow
    let document: Document
    let columnWidth: CGFloat

    var body: some View {
        if case .gap(let count) = row.kind {
            Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidth * 2 + 1)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.08))
        } else {
            HStack(spacing: 0) {
                side(row.left, color: leftColor)
                Divider()
                side(row.right, color: rightColor)
            }
            .frame(width: columnWidth * 2 + 1, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // Back to the editor at this line.
                guard let line = row.right?.number ?? row.left?.number else { return }
                workspace.diffDocumentID = nil
                document.revealTarget = RevealTarget(position: TextPosition(line: line - 1, character: 0))
            }
        }
    }

    private var leftColor: Color? {
        switch row.kind {
        case .removed, .changed: .red.opacity(0.16)
        default: nil
        }
    }

    private var rightColor: Color? {
        switch row.kind {
        case .added: .green.opacity(0.18)
        case .changed: .blue.opacity(0.14)
        default: nil
        }
    }

    private func side(_ line: (number: Int, text: String)?, color: Color?) -> some View {
        HStack(spacing: 8) {
            Text(line.map { "\($0.number)" } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Text(line?.text.replacingOccurrences(of: "\t", with: "    ") ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(width: columnWidth, alignment: .leading)
        .background(color ?? (line == nil ? Color.secondary.opacity(0.06) : .clear))
        .clipped()
    }
}
