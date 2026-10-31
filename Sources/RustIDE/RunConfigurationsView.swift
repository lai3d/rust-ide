import RustIDECore
import SwiftUI

/// Toolbar menu: pick the configuration ⌘R and ⌥⌘R use.
struct RunConfigurationPicker: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu {
            ForEach(workspace.runConfigurations) { config in
                Button {
                    workspace.selectedRunConfigurationID = config.id
                } label: {
                    if config.id == workspace.selectedRunConfiguration?.id {
                        Label(config.name, systemImage: "checkmark")
                    } else {
                        Text(config.name)
                    }
                }
            }
            Divider()
            Button("Edit Configurations…") { workspace.isEditingRunConfigurations = true }
        } label: {
            Label(workspace.selectedRunConfiguration?.name ?? "No main package", systemImage: "terminal")
                .labelStyle(.titleAndIcon)
        }
        .help("Run configuration (⌘R runs it, ⌥⌘R debugs it)")
        .disabled(workspace.rootURL == nil)
    }
}

/// Sheet for adding/editing run configurations.
struct RunConfigurationsSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(workspace.runConfigurations) { Text($0.name).tag($0.id) }
                    }
                    HStack(spacing: 2) {
                        Button { add() } label: { Image(systemName: "plus") }
                        Button { remove() } label: { Image(systemName: "minus") }
                            .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(minWidth: 160, idealWidth: 180)

                Group {
                    if let index = workspace.runConfigurations.firstIndex(where: { $0.id == selection }) {
                        Form {
                            TextField("Name", text: $workspace.runConfigurations[index].name)
                            Picker("Package", selection: $workspace.runConfigurations[index].package) {
                                ForEach(packageChoices(including: workspace.runConfigurations[index].package), id: \.self) {
                                    Text($0 == "." ? ". (project root)" : "./" + $0).tag($0)
                                }
                            }
                            TextField("Arguments", text: $workspace.runConfigurations[index].arguments,
                                      prompt: Text("-port 8080 --name \"my app\""))
                                .font(.system(.body, design: .monospaced))
                            LabeledContent("Environment") {
                                TextEditor(text: $workspace.runConfigurations[index].environment)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 90)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                            }
                            Text("One KEY=value per line. Used by Run (⌘R) and Debug (⌥⌘R).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    } else {
                        Text("Select or add a configuration.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 470)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    if let selection { workspace.selectedRunConfigurationID = selection }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 720, height: 330)
        .onAppear {
            workspace.refreshMainPackages()
            selection = workspace.selectedRunConfiguration?.id
        }
    }

    private func packageChoices(including current: String) -> [String] {
        workspace.mainPackages.contains(current) ? workspace.mainPackages : [current] + workspace.mainPackages
    }

    private func add() {
        let package = workspace.mainPackages.first ?? "."
        let config = RunConfiguration(name: "New Configuration", package: package)
        workspace.runConfigurations.append(config)
        selection = config.id
    }

    private func remove() {
        workspace.runConfigurations.removeAll { $0.id == selection }
        selection = workspace.runConfigurations.first?.id
    }
}
