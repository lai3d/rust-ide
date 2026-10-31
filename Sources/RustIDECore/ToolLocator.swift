import Foundation

/// Finds Go tooling. GUI apps launched from Finder get a minimal PATH, so we
/// also look in the usual Go and Homebrew install locations.
public enum ToolLocator {
    public static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let gobin = environment["GOBIN"] { dirs.append(gobin) }
        if let gopath = environment["GOPATH"] {
            dirs += gopath.split(separator: ":").map { "\($0)/bin" }
        }
        dirs += ["\(home)/go/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin",
                 "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// UserDefaults key for a user-chosen tool path (set in Settings).
    public static func overrideKey(for name: String) -> String { "toolPath.\(name)" }

    public static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let custom = UserDefaults.standard.string(forKey: overrideKey(for: name))?
            .trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in searchDirectories(environment: environment) {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// The current environment with PATH widened to every search directory,
    /// so child processes (gopls, go) can find each other.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["PATH"] = searchDirectories(environment: base).joined(separator: ":")
        return env
    }
}

public extension URL {
    /// The canonical file URL as the OS (and gopls) sees it: symlinks resolved and
    /// `/tmp` → `/private/tmp`. Unlike `resolvingSymlinksInPath()`, keeps `/private`.
    var canonicalFileURL: URL {
        guard isFileURL, let resolved = realpath(path, nil) else { return standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}
