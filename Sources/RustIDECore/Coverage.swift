import Foundation

/// Line coverage from an LCOV file (`cargo llvm-cov --lcov`), for files in the project.
public struct CoverageReport: Sendable, Hashable {
    public struct FileCoverage: Sendable, Hashable {
        /// Zero-based line → covered (true) / not covered (false). Lines without code are absent.
        public var lines: [Int: Bool] = [:]
        /// Instrumented lines and how many of them ran.
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

    /// Parses `SF:<path>` / `DA:<line>,<count>` / `end_of_record`. Files outside `root`
    /// (dependencies, the standard library) are skipped. A line listed twice counts as covered
    /// if any entry ran.
    public static func parseLCOV(_ lcov: String, root: String) -> CoverageReport {
        var report = CoverageReport()
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var path: String?
        var lines: [Int: Bool] = [:]
        func flush() {
            if let path, path.hasPrefix(prefix), !lines.isEmpty {
                var file = report.files[path, default: FileCoverage()]
                for (line, covered) in lines { file.lines[line] = (file.lines[line] ?? false) || covered }
                file.statements = file.lines.count
                file.coveredStatements = file.lines.values.filter { $0 }.count
                report.files[path] = file
            }
            path = nil
            lines = [:]
        }
        for raw in lcov.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") {
                flush()
                path = String(line.dropFirst(3))
            } else if line.hasPrefix("DA:") {
                let fields = line.dropFirst(3).split(separator: ",")
                guard fields.count >= 2, let number = Int(fields[0]), let count = Int(fields[1]), number > 0 else { continue }
                lines[number - 1] = (lines[number - 1] ?? false) || count > 0
            } else if line == "end_of_record" {
                flush()
            }
        }
        flush()
        return report
    }
}
