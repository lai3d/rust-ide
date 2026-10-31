import Foundation
import RustIDECore

/// Recent projects and per-project open tabs, in UserDefaults.
@MainActor
enum SessionStore {
    private static let recentsKey = "recentProjects"
    private static let maxRecents = 12
    static let reopenLastKey = "reopenLastProject"

    static var defaults = UserDefaults.standard

    /// Most recent first; folders that no longer exist are dropped.
    static var recentProjects: [URL] {
        (defaults.stringArray(forKey: recentsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func noteOpened(_ folder: URL) {
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == folder.path }
        paths.insert(folder.path, at: 0)
        defaults.set(Array(paths.prefix(maxRecents)), forKey: recentsKey)
        ToolboxRecents.record(folder)
    }

    static func clearRecents() {
        defaults.removeObject(forKey: recentsKey)
    }

    struct Session: Codable, Equatable {
        var openFiles: [String]
        var activeFile: String?
    }

    static func session(for folder: URL) -> Session? {
        guard let data = defaults.data(forKey: "session:" + folder.path) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session, for folder: URL) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: "session:" + folder.path)
    }

    static func runConfigurations(for folder: URL) -> (configs: [RunConfiguration], selected: UUID?)? {
        guard let data = defaults.data(forKey: "runConfigs:" + folder.path),
              let configs = try? JSONDecoder().decode([RunConfiguration].self, from: data) else { return nil }
        let selected = defaults.string(forKey: "runConfigSelected:" + folder.path).flatMap(UUID.init(uuidString:))
        return (configs, selected)
    }

    static func saveRunConfigurations(_ configs: [RunConfiguration], selected: UUID?, for folder: URL) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: "runConfigs:" + folder.path)
        defaults.set(selected?.uuidString, forKey: "runConfigSelected:" + folder.path)
    }

    static var reopenLastProject: Bool {
        defaults.object(forKey: reopenLastKey) as? Bool ?? true
    }
}
