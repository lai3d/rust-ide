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
            Label(workspace.selectedRunConfiguration?.name ?? "No binary target", systemImage: "terminal")
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
                            Picker("Target", selection: targetBinding(index)) {
                                ForEach(targetChoices(including: workspace.runConfigurations[index]), id: \.self) { target in
                                    Text(label(for: target)).tag(target)
                                }
                            }
                            TextField("Features", text: $workspace.runConfigurations[index].features,
                                      prompt: Text("tls metrics"))
                                .font(.system(.body, design: .monospaced))
                            Toggle("Release profile (--release)", isOn: $workspace.runConfigurations[index].release)
                            TextField("Arguments", text: $workspace.runConfigurations[index].arguments,
                                      prompt: Text("--port 8080 --name \"my app\""))
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
        .frame(width: 720, height: 380)
        .onAppear {
            selection = workspace.selectedRunConfiguration?.id
            Task { await workspace.refreshCargoMetadata() }
        }
    }

    /// A configuration's target as a picker value.
    private struct TargetChoice: Hashable {
        var package: String
        var name: String
        var kind: CargoTarget.Kind
    }

    private func targetChoices(including config: RunConfiguration) -> [TargetChoice] {
        let known = workspace.runTargets.map { TargetChoice(package: $0.package, name: $0.name, kind: $0.kind) }
        let current = TargetChoice(package: config.package, name: config.target, kind: config.kind)
        return known.contains(current) ? known : [current] + known
    }

    private func label(for target: TargetChoice) -> String {
        let packages = Set(workspace.runTargets.map(\.package))
        let suffix = target.kind == .example ? " (example)" : ""
        return packages.count > 1 ? "\(target.package) › \(target.name)\(suffix)" : target.name + suffix
    }

    private func targetBinding(_ index: Int) -> Binding<TargetChoice> {
        Binding {
            let config = workspace.runConfigurations[index]
            return TargetChoice(package: config.package, name: config.target, kind: config.kind)
        } set: { choice in
            workspace.runConfigurations[index].package = choice.package
            workspace.runConfigurations[index].target = choice.name
            workspace.runConfigurations[index].kind = choice.kind
        }
    }

    private func add() {
        let config = workspace.runTargets.first.map(RunConfiguration.init(target:))
            ?? RunConfiguration(name: "New Configuration", target: "")
        workspace.runConfigurations.append(config)
        selection = config.id
    }

    private func remove() {
        workspace.runConfigurations.removeAll { $0.id == selection }
        selection = workspace.runConfigurations.first?.id
    }
}
