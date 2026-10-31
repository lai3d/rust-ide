import RustIDECore
import SwiftUI

/// Git sidebar: staged and unstaged changes, commit message, commit.
struct SourceControlView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        if !workspace.isGitRepository {
            Text("This folder isn't in a Git repository.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let staged = workspace.gitChanges.filter(\.isStaged)
            let unstaged = workspace.gitChanges.filter(\.hasUnstagedChanges)
            VStack(alignment: .leading, spacing: 6) {
                if let branch = workspace.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                }
                TextEditor(text: $workspace.commitMessage)
                    .font(.system(size: 12))
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if workspace.commitMessage.isEmpty {
                            Text("Commit message").foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                    .padding(.horizontal, 10)
                HStack {
                    if staged.isEmpty {
                        Button("Stage All & Commit") { Task { await workspace.commit(stageAll: true) } }
                            .disabled(unstaged.isEmpty)
                    } else {
                        Button("Commit \(staged.count) File\(staged.count == 1 ? "" : "s")") {
                            Task { await workspace.commit() }
                        }
                    }
                    Spacer()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.small)
                .padding(.horizontal, 10)
                if let error = workspace.gitError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).padding(.horizontal, 12)
                }
                List {
                    if !staged.isEmpty {
                        Section {
                            ForEach(staged) { ChangeRow(change: $0, staged: true) }
                        } header: {
                            sectionHeader("Staged", count: staged.count) {
                                Button("Unstage All") { Task { await workspace.unstage(staged) } }
                            }
                        }
                    }
                    Section {
                        ForEach(unstaged) { ChangeRow(change: $0, staged: false) }
                        if unstaged.isEmpty { Text("No changes").foregroundStyle(.secondary) }
                    } header: {
                        sectionHeader("Changes", count: unstaged.count) {
                            Button("Stage All") { Task { await workspace.stage(unstaged) } }
                                .disabled(unstaged.isEmpty)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Text("\(title) (\(count))")
            Spacer()
            action().buttonStyle(.link).font(.caption)
        }
    }
}

private struct ChangeRow: View {
    @Environment(Workspace.self) private var workspace
    let change: GitChange
    let staged: Bool

    var body: some View {
        let url = URL(fileURLWithPath: change.path)
        let letter = staged ? change.index : (change.isUntracked ? "?" : change.workTree)
        HStack(spacing: 6) {
            Text(String(letter))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: letter))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).lineLimit(1)
                let folder = (workspace.displayPath(url.deletingLastPathComponent().path))
                if !folder.isEmpty, folder != url.deletingLastPathComponent().path {
                    Text(folder).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if staged {
                iconButton("minus", "Unstage") { await workspace.unstage([change]) }
            } else {
                iconButton("arrow.uturn.backward", "Discard Changes") {
                    guard Prompt.confirm(title: "Discard changes to “\(url.lastPathComponent)”?",
                                         message: change.isUntracked ? "The file is moved to the Trash."
                                                                      : "This can't be undone.",
                                         confirm: "Discard") else { return }
                    await workspace.discard([change])
                }
                iconButton("plus", "Stage") { await workspace.stage([change]) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Open the file and show what changed.
            guard FileManager.default.fileExists(atPath: change.path), let document = workspace.openFile(url) else { return }
            if !change.isUntracked { workspace.diffDocumentID = document.id }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol).frame(width: 14) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private func color(for letter: Character) -> Color {
        switch letter {
        case "M", "R": .orange
        case "A", "?": .green
        case "D", "U": .red
        default: .secondary
        }
    }
}
