import Foundation

public enum GitFileStatus: String, Sendable, Hashable {
    case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "U"
}

/// Small synchronous wrappers around the `git` CLI (call off the main thread).
public enum Git {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    @discardableResult
    public static func run(_ arguments: [String], in directory: URL, input: String? = nil) -> Result {
        guard let git = ToolLocator.find("git") else { return Result(status: -1, output: "") }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ToolLocator.environment()
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "")
        }
        if let stdin, let input {
            // git reads all of stdin before writing output, so a plain write can't deadlock.
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The repository's top-level directory, or nil if `directory` isn't in a Git work tree.
    public static func topLevel(of directory: URL) -> URL? {
        let result = run(["rev-parse", "--show-toplevel"], in: directory)
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? URL(fileURLWithPath: path).canonicalFileURL : nil
    }

    public static func currentBranch(in directory: URL) -> String? {
        let branch = run(["branch", "--show-current"], in: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { return branch }
        let head = run(["rev-parse", "--short", "HEAD"], in: directory)  // detached HEAD
        return head.status == 0 ? "(" + head.output.trimmingCharacters(in: .whitespacesAndNewlines) + ")" : nil
    }

    /// Statuses keyed by absolute path, from `git status --porcelain=v1 -z`.
    public static func status(in topLevel: URL) -> [String: GitFileStatus] {
        // --no-optional-locks: don't rewrite .git/index (which would retrigger our file watcher).
        let result = run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], in: topLevel)
        guard result.status == 0 else { return [:] }
        return parseStatus(result.output, root: topLevel.path)
    }

    public static func parseStatus(_ porcelain: String, root: String) -> [String: GitFileStatus] {
        var statuses: [String: GitFileStatus] = [:]
        var entries = porcelain.split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex], y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            let status: GitFileStatus
            switch (x, y) {
            case ("?", "?"): status = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
            case ("R", _), ("C", _):
                status = .renamed
                _ = entries.popFirst()  // -z puts the original path in the next field
            case ("A", _): status = .added
            case ("D", _), (_, "D"): status = .deleted
            default: status = .modified
            }
            statuses[(root as NSString).appendingPathComponent(path)] = status
        }
        return statuses
    }

    /// Index (staged) and work-tree states per changed file.
    public static func changes(in topLevel: URL) -> [GitChange] {
        let result = run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], in: topLevel)
        guard result.status == 0 else { return [] }
        return GitChange.parse(result.output, root: topLevel.path)
    }

    /// Runs a git command; returns nil on success, else git's error output.
    private static func mutate(_ arguments: [String], in topLevel: URL, input: String? = nil) -> String? {
        guard let git = ToolLocator.find("git") else { return "git not found" }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = topLevel
        process.environment = ToolLocator.environment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        do { try process.run() } catch { return error.localizedDescription }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 ? nil : (text.isEmpty ? "git \(arguments.first ?? "") failed" : text)
    }

    public static func stage(_ paths: [String], in topLevel: URL) -> String? {
        mutate(["add", "--"] + paths, in: topLevel)
    }

    public static func unstage(_ paths: [String], in topLevel: URL) -> String? {
        mutate(["restore", "--staged", "--"] + paths, in: topLevel)
    }

    /// Drops work-tree changes of tracked files.
    public static func discard(_ paths: [String], in topLevel: URL) -> String? {
        mutate(["restore", "--"] + paths, in: topLevel)
    }

    public static func commit(message: String, in topLevel: URL) -> String? {
        mutate(["commit", "-q", "-F", "-"], in: topLevel, input: message)
    }

    /// Who last changed a (zero-based) line, blaming `contents` (the editor buffer) so line
    /// numbers match unsaved edits; changed lines come back as uncommitted.
    public static func blame(file: URL, line: Int, contents: String, topLevel: URL) -> BlameLine? {
        let relative = String(file.canonicalFileURL.path.dropFirst(topLevel.path.count + 1))
        let result = run(["blame", "--porcelain", "-L", "\(line + 1),\(line + 1)", "--contents", "-", "--", relative],
                         in: topLevel, input: contents)
        guard result.status == 0 else { return nil }
        return BlameLine.parse(porcelain: result.output)
    }

    /// A file's contents at HEAD (nil if it isn't tracked there).
    public static func headContents(of file: URL, topLevel: URL) -> String? {
        let relative = String(file.canonicalFileURL.path.dropFirst(topLevel.path.count + 1))
        let result = run(["show", "HEAD:" + relative], in: topLevel)
        return result.status == 0 ? result.output : nil
    }
}

/// Line-level changes of the current text against a base (e.g. HEAD), for gutter bars.
public struct LineChanges: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case added, modified }

    /// Zero-based lines in the current text.
    public var lines: [Int: Kind] = [:]
    /// Lines in the current text *before which* base lines were deleted.
    public var deletions: Set<Int> = []

    public init(lines: [Int: Kind] = [:], deletions: Set<Int> = []) {
        self.lines = lines
        self.deletions = deletions
    }

    public var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    public static func compute(base: String, current: String) -> LineChanges {
        let old = base.components(separatedBy: "\n"), new = current.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var changes = LineChanges()
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                // A hunk: consecutive removals/insertions. Paired lines are "modified".
                var removedCount = 0
                var added: [Int] = []
                var progressed = true
                while progressed {
                    progressed = false
                    while i < old.count, removed.contains(i) { removedCount += 1; i += 1; progressed = true }
                    while j < new.count, inserted.contains(j) { added.append(j); j += 1; progressed = true }
                }
                if added.isEmpty {
                    changes.deletions.insert(j)
                } else {
                    for (k, line) in added.enumerated() { changes.lines[line] = k < removedCount ? .modified : .added }
                }
            } else {
                i += 1
                j += 1
            }
        }
        return changes
    }
}

/// One line of `git blame --porcelain`.
public struct BlameLine: Sendable, Hashable {
    public let commit: String
    public let author: String
    public let date: Date
    public let summary: String

    public var isUncommitted: Bool { commit.allSatisfy { $0 == "0" } }

    public static func parse(porcelain: String) -> BlameLine? {
        let lines = porcelain.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first, let commit = header.split(separator: " ").first, commit.count >= 7 else { return nil }
        var author = "", summary = "", time: TimeInterval = 0
        for line in lines.dropFirst() {
            if line.hasPrefix("author ") { author = String(line.dropFirst(7)) }
            else if line.hasPrefix("author-time ") { time = TimeInterval(line.dropFirst(12)) ?? 0 }
            else if line.hasPrefix("summary ") { summary = String(line.dropFirst(8)) }
            else if line.hasPrefix("\t") { break }  // the line's content ends the header
        }
        return BlameLine(commit: String(commit), author: author, date: Date(timeIntervalSince1970: time), summary: summary)
    }
}

/// One row of a side-by-side diff.
public struct DiffRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case same, added, removed, changed
        /// Unchanged lines folded away.
        case gap(Int)
    }

    public let id: Int
    public let kind: Kind
    /// One-based line numbers and texts; nil where that side has no line.
    public let left: (number: Int, text: String)?
    public let right: (number: Int, text: String)?

    public static func == (a: DiffRow, b: DiffRow) -> Bool {
        a.id == b.id && a.kind == b.kind && a.left?.number == b.left?.number && a.left?.text == b.left?.text
            && a.right?.number == b.right?.number && a.right?.text == b.right?.text
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum SideBySideDiff {
    /// Aligned rows: removed/added lines in a hunk pair up as `changed`; long unchanged
    /// stretches collapse to a `gap`, keeping `context` lines around each change.
    public static func rows(base: String, current: String, context: Int = 3) -> [DiffRow] {
        var old = base.components(separatedBy: "\n"), new = current.components(separatedBy: "\n")
        if old.last == "" { old.removeLast() }
        if new.last == "" { new.removeLast() }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Full alignment first.
        var full: [(DiffRow.Kind, (Int, String)?, (Int, String)?)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) || inserted.contains(j) {
                var gone: [Int] = [], added: [Int] = []
                var progressed = true
                while progressed {
                    progressed = false
                    while i < old.count, removed.contains(i) { gone.append(i); i += 1; progressed = true }
                    while j < new.count, inserted.contains(j) { added.append(j); j += 1; progressed = true }
                }
                for k in 0..<max(gone.count, added.count) {
                    let l = k < gone.count ? (gone[k] + 1, old[gone[k]]) : nil
                    let r = k < added.count ? (added[k] + 1, new[added[k]]) : nil
                    full.append((l != nil && r != nil ? .changed : (l != nil ? .removed : .added), l, r))
                }
            } else {
                full.append((.same, (i + 1, old[i]), (j + 1, new[j])))
                i += 1
                j += 1
            }
        }
        // Keep `context` lines around changes; fold the rest.
        let changed = full.indices.filter { full[$0].0 != .same }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(full.count - 1, index + context) { keep.insert(k) }
        }
        var rows: [DiffRow] = []
        var hidden = 0
        for (index, entry) in full.enumerated() {
            if keep.contains(index) {
                if hidden > 0 {
                    rows.append(DiffRow(id: rows.count, kind: .gap(hidden), left: nil, right: nil))
                    hidden = 0
                }
                rows.append(DiffRow(id: rows.count, kind: entry.0,
                                    left: entry.1.map { (number: $0.0, text: $0.1) },
                                    right: entry.2.map { (number: $0.0, text: $0.1) }))
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { rows.append(DiffRow(id: rows.count, kind: .gap(hidden), left: nil, right: nil)) }
        return rows
    }
}

/// A changed file with its staged (index) and unstaged (work tree) states.
public struct GitChange: Sendable, Hashable, Identifiable {
    public let path: String
    /// Porcelain X (index) and Y (work tree) columns, e.g. "M", "A", "D", "?", " ".
    public let index: Character
    public let workTree: Character

    public var id: String { path }
    public var isUntracked: Bool { index == "?" }
    public var isStaged: Bool { index != " " && index != "?" }
    public var hasUnstagedChanges: Bool { workTree != " " }

    public static func parse(_ porcelain: String, root: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = porcelain.split(separator: "\0", omittingEmptySubsequences: true)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex], y = entry[entry.index(after: entry.startIndex)]
            if x == "R" || x == "C" { _ = entries.popFirst() }  // original path follows
            changes.append(GitChange(path: (root as NSString).appendingPathComponent(String(entry.dropFirst(3))),
                                     index: x, workTree: y))
        }
        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
