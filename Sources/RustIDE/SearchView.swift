import RustIDECore
import SwiftUI

/// Find in project: query field, options, and results grouped by file.
struct SearchView: View {
    @Environment(Workspace.self) private var workspace
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var workspace = workspace
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { workspace.isReplaceVisible.toggle() } label: {
                    Image(systemName: workspace.isReplaceVisible ? "chevron.down" : "chevron.right")
                        .frame(width: 10)
                }
                .buttonStyle(.borderless)
                .help("Toggle Replace")
                TextField("Find in project", text: $workspace.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { Task { await workspace.performSearch() } }
                OptionToggle(label: "Aa", help: "Match Case", isOn: $workspace.searchOptions.caseSensitive)
                OptionToggle(label: "ab", help: "Whole Word", isOn: $workspace.searchOptions.wholeWord, underline: true)
                OptionToggle(label: ".*", help: "Regular Expression", isOn: $workspace.searchOptions.regex)
            }
            .padding(.horizontal, 10)

            if workspace.isReplaceVisible {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 14, height: 1)
                    TextField(workspace.searchOptions.regex ? "Replace ($1 for groups)" : "Replace", text: $workspace.replaceQuery)
                        .textFieldStyle(.roundedBorder)
                    Button("Replace All") { confirmReplaceAll() }
                        .controlSize(.small)
                        .disabled(workspace.searchResults.isEmpty)
                }
                .padding(.horizontal, 10)
            }

            Group {
                if let error = workspace.searchError {
                    Text(error).foregroundStyle(.red)
                } else if workspace.isSearching {
                    Text("Searching…")
                } else if !workspace.searchQuery.isEmpty {
                    let files = workspace.searchResults.count
                    Text("\(workspace.searchMatchCount) results in \(files) file\(files == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 12)

            List {
                ForEach(workspace.searchResults) { file in
                    Section {
                        ForEach(file.matches) { match in
                            HStack(spacing: 2) {
                                Button { workspace.open(match, in: file) } label: {
                                    MatchRow(match: match, replacement: replacementPreview(for: match))
                                }
                                .buttonStyle(.plain)
                                if workspace.isReplaceVisible {
                                    Button { Task { await workspace.replace(match, in: file) } } label: {
                                        Image(systemName: "arrow.2.squarepath")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Replace this match")
                                }
                            }
                        }
                    } header: {
                        FileHeader(path: workspace.displayPath(file.path), count: file.matches.count)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onChange(of: workspace.searchQuery) { workspace.scheduleSearch() }
        .onChange(of: workspace.searchOptions) { workspace.scheduleSearch() }
        .onChange(of: workspace.searchFocusRequest, initial: true) { fieldFocused = true }
    }

    private func replacementPreview(for match: SearchMatch) -> String? {
        guard workspace.isReplaceVisible, let (regex, template) = workspace.replacePattern,
              let range = Range(match.previewRange, in: match.preview) else { return nil }
        return ProjectSearch.preview(of: String(match.preview[range]), regex: regex, template: template)
    }

    private func confirmReplaceAll() {
        let count = workspace.searchMatchCount, files = workspace.searchResults.count
        guard Prompt.confirm(
            title: "Replace \(count) occurrence\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")?",
            message: "Open files change in the editor (undoable); other files are written to disk.",
            confirm: "Replace All") else { return }
        Task { await workspace.replaceAllInProject() }
    }
}

private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var underline = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .frame(width: 18)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .help(help)
    }
}

struct FileHeader: View {
    let path: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text").font(.caption)
            Text((path as NSString).lastPathComponent).fontWeight(.semibold)
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .background(.quaternary, in: Capsule())
        }
        .font(.callout)
    }
}

struct MatchRow: View {
    let match: SearchMatch
    var replacement: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line + 1)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 26, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    private var highlighted: AttributedString {
        guard let range = Range(match.previewRange, in: match.preview) else { return AttributedString(match.preview) }
        var before = AttributedString(String(match.preview[..<range.lowerBound]))
        var found = AttributedString(String(match.preview[range]))
        let after = AttributedString(String(match.preview[range.upperBound...]))
        if let replacement {
            // Preview: old text struck through, new text in green.
            found.strikethroughStyle = .single
            found.backgroundColor = .red.opacity(0.18)
            var new = AttributedString(replacement)
            new.backgroundColor = .green.opacity(0.25)
            before.append(found)
            before.append(new)
        } else {
            found.backgroundColor = .yellow.opacity(0.45)
            found.foregroundColor = .primary
            before.append(found)
        }
        before.append(after)
        return before
    }
}
