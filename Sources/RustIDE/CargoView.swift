import AppKit
import RustIDECore
import SwiftUI

/// Sidebar ▸ Cargo: each package's features (toggles) and dependencies, with Cargo.lock versions.
struct CargoView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let metadata = workspace.cargoMetadata, !metadata.packages.isEmpty {
            VStack(spacing: 0) {
                toolbar(metadata)
                Divider()
                List {
                    ForEach(metadata.packages, id: \.manifestPath) { package in
                        PackageSection(package: package, showName: metadata.packages.count > 1)
                    }
                }
                .listStyle(.sidebar)
            }
        } else {
            ContentUnavailableView("No Cargo Project", systemImage: "shippingbox",
                                   description: Text("Open a folder with a Cargo.toml."))
        }
    }

    private func toolbar(_ metadata: CargoMetadata) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(metadata.packages, id: \.manifestPath) { package in
                    if metadata.packages.count > 1 {
                        Section(package.name) { addButtons(package) }
                    } else {
                        addButtons(package)
                    }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a dependency (cargo add)")
            Spacer()
            Button { workspace.runCargo(["update"]) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderless)
                .help("Update all dependencies in Cargo.lock (cargo update)")
            Button { Task { await workspace.refreshCargoMetadata() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload cargo metadata")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func addButtons(_ package: CargoPackage) -> some View {
        ForEach(CargoDependency.Kind.allCases, id: \.self) { kind in
            Button(kind == .normal ? "Add Dependency…" : "Add \(kind == .dev ? "Dev" : "Build") Dependency…") {
                promptAdd(kind: kind, to: package)
            }
        }
    }

    private func promptAdd(kind: CargoDependency.Kind, to package: CargoPackage) {
        guard let spec = Prompt.text(
            title: "Add \(kind == .normal ? "" : kind.rawValue + "-")dependency to \(package.name)",
            message: "Crate name, optionally with a version and cargo add flags, e.g. serde@1 --features derive",
            initial: "", confirm: "Add") else { return }
        workspace.addDependency(spec, kind: kind, to: package)
    }
}

private struct PackageSection: View {
    @Environment(Workspace.self) private var workspace
    let package: CargoPackage
    let showName: Bool

    var body: some View {
        if showName {
            Section {
                content
            } header: {
                header
            }
        } else {
            header.listRowSeparator(.hidden)
            content
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "shippingbox")
            Text(package.name).font(.headline)
            Spacer()
            Button("Cargo.toml") { workspace.openManifest(of: package) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !package.features.isEmpty {
            ExpandableGroup(initiallyExpanded: true) {
                if !package.defaultFeatures.isEmpty {
                    Text("default = \(package.defaultFeatures.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(package.features, id: \.self) { feature in
                    Toggle(isOn: Binding(
                        get: { workspace.isFeatureEnabled(feature, in: package) },
                        set: { workspace.setFeature(feature, in: package, enabled: $0) })) {
                        Text(feature).font(.system(.body, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .help(package.featureMap[feature].map { $0.isEmpty ? "Enables nothing else" : "Enables " + $0.joined(separator: ", ") } ?? "")
                }
            } label: {
                Label("Features", systemImage: "switch.2")
                    .badge(package.features.filter { workspace.isFeatureEnabled($0, in: package) }.count)
            }
        }
        ForEach(CargoDependency.Kind.allCases, id: \.self) { kind in
            let dependencies = package.dependencies.filter { $0.kind == kind }.sorted { $0.name < $1.name }
            if !dependencies.isEmpty {
                ExpandableGroup(initiallyExpanded: kind == .normal) {
                    ForEach(dependencies) { dependency in
                        DependencyRow(dependency: dependency, package: package)
                    }
                } label: {
                    Label(kind.title, systemImage: kind == .normal ? "cube" : kind == .dev ? "hammer" : "gearshape")
                        .badge(dependencies.count)
                }
            }
        }
    }
}

private struct DependencyRow: View {
    @Environment(Workspace.self) private var workspace
    let dependency: CargoDependency
    let package: CargoPackage

    private var locked: [String] { workspace.lockedVersions[dependency.name] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(dependency.rename.map { "\($0) → \(dependency.name)" } ?? dependency.name)
                    .font(.system(.body, design: .monospaced))
                Spacer(minLength: 4)
                if dependency.optional { badge("optional") }
                switch dependency.source {
                case .path: badge("path")
                case .git: badge("git")
                case .registry: EmptyView()
                }
            }
            HStack(spacing: 4) {
                Text(dependency.req)
                if !locked.isEmpty { Text("· locked \(locked.joined(separator: ", "))") }
                if let target = dependency.target { Text("· \(target)").lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help(dependency.features.isEmpty ? "" : "features: " + dependency.features.joined(separator: ", "))
        .contextMenu {
            if dependency.isRegistry {
                Button("Open Documentation (docs.rs)") { open("https://docs.rs/\(dependency.name)/\(locked.last ?? "latest")") }
                Button("Open on crates.io") { open("https://crates.io/crates/\(dependency.name)") }
                Divider()
            }
            Button("Update in Cargo.lock (cargo update -p \(dependency.name))") { workspace.updateDependency(dependency) }
            Button("Remove (cargo remove)…") {
                if Prompt.confirm(title: "Remove \(dependency.rename ?? dependency.name)?",
                                  message: "Runs cargo remove on \(package.name)'s Cargo.toml.", confirm: "Remove") {
                    workspace.removeDependency(dependency, from: package)
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(.quaternary, in: Capsule())
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

/// A DisclosureGroup that remembers its own expansion, starting open or closed.
private struct ExpandableGroup<Content: View, Label: View>: View {
    @State private var isExpanded: Bool
    private let content: Content
    private let label: Label

    init(initiallyExpanded: Bool, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content()
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) { content } label: { label }
    }
}
