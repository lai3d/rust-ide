import Foundation

/// A parsed `go test -coverprofile` file, mapped to files on disk.
public struct CoverageReport: Sendable, Hashable {
    public struct FileCoverage: Sendable, Hashable {
        /// Zero-based line → covered (true) / not covered (false). Lines without statements are absent.
        public var lines: [Int: Bool] = [:]
        public var statements = 0
        public var coveredStatements = 0

        public var percent: Double {
            statements == 0 ? 0 : Double(coveredStatements) / Double(statements) * 100
        }
    }

    /// Keyed by absolute file path.
    public var files: [String: FileCoverage] = [:]

    public var percent: Double {
        let total = files.values.reduce(0) { $0 + $1.statements }
        let covered = files.values.reduce(0) { $0 + $1.coveredStatements }
        return total == 0 ? 0 : Double(covered) / Double(total) * 100
    }

    public init() {}

    /// The `module` path declared in a go.mod file.
    public static func modulePath(goMod: String) -> String? {
        for line in goMod.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("module ") {
                return trimmed.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    /// Parses `file.go:startLine.startCol,endLine.endCol statements count` blocks.
    /// Import paths under `modulePath` map into `root`; others are skipped.
    public static func parse(_ profile: String, modulePath: String, root: String) -> CoverageReport {
        var report = CoverageReport()
        // A block can appear several times (e.g. once per test binary): keep the max count.
        var blocks: [String: (statements: Int, count: Int, start: Int, end: Int)] = [:]
        for line in profile.split(separator: "\n") where !line.hasPrefix("mode:") {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let file = String(line[..<colon])
            let fields = line[line.index(after: colon)...].split(separator: " ")
            guard fields.count == 3, let statements = Int(fields[1]), let count = Int(fields[2]) else { continue }
            let span = fields[0].split(separator: ",")
            guard span.count == 2,
                  let startLine = Int(span[0].split(separator: ".").first ?? ""),
                  let endLine = Int(span[1].split(separator: ".").first ?? "")
            else { continue }
            let key = file + ":" + fields[0]
            let previous = blocks[key]?.count ?? 0
            blocks[key] = (statements, max(previous, count), startLine, endLine)
        }
        for (key, block) in blocks {
            let importPath = String(key[..<key.lastIndex(of: ":")!])
            guard importPath.hasPrefix(modulePath + "/") else { continue }
            let path = (root as NSString).appendingPathComponent(String(importPath.dropFirst(modulePath.count + 1)))
            var file = report.files[path, default: FileCoverage()]
            file.statements += block.statements
            if block.count > 0 { file.coveredStatements += block.statements }
            for line in (block.start - 1)...(block.end - 1) {
                // Covered wins when blocks overlap a line.
                file.lines[line] = (file.lines[line] ?? false) || block.count > 0
            }
            report.files[path] = file
        }
        return report
    }
}
