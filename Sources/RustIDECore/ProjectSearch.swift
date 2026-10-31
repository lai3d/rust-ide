import Foundation

public struct SearchOptions: Sendable, Hashable {
    public var caseSensitive = false
    public var wholeWord = false
    public var regex = false

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

public struct SearchMatch: Sendable, Hashable, Identifiable {
    public let id = UUID()
    /// Zero-based line and UTF-16 column of the match start.
    public let line: Int
    public let column: Int
    /// Match length in UTF-16 units.
    public let length: Int
    /// The (trimmed, possibly shortened) line, and where the match sits in it.
    public let preview: String
    public let previewRange: NSRange
}

public struct SearchFileResult: Sendable, Hashable, Identifiable {
    public let path: String
    public let matches: [SearchMatch]
    public var id: String { path }
}

public enum ProjectSearch {
    public static let maxFileSize = 2 * 1024 * 1024
    public static let maxPreviewLength = 160

    public static func makeRegex(_ query: String, options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = #"\b(?:"# + pattern + #")\b"# }
        return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    /// All non-empty matches of `regex` in `text`.
    public static func matches(of regex: NSRegularExpression, in text: String, limit: Int = .max) -> [SearchMatch] {
        let ns = text as NSString
        let index = LineIndex(text)
        var results: [SearchMatch] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let range = match?.range, range.length > 0 else { return }
            let position = index.position(of: range.location)
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let (preview, previewRange) = makePreview(ns, line: lineRange, match: range)
            results.append(SearchMatch(line: position.line, column: position.character, length: range.length,
                                       preview: preview, previewRange: previewRange))
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    /// Turns LSP locations (e.g. references) into per-file results with line previews.
    /// `text` supplies a file's contents (open buffer or disk) by path.
    public static func results(for locations: [Location], text: (String) -> String?) -> [SearchFileResult] {
        var byPath: [String: [Location]] = [:]
        for location in locations {
            guard let url = URL(string: location.uri), url.isFileURL else { continue }
            byPath[url.path, default: []].append(location)
        }
        return byPath.compactMap { path, locations -> SearchFileResult? in
            guard let contents = text(path) else { return nil }
            let ns = contents as NSString
            let index = LineIndex(contents)
            let matches = locations
                .sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
                .map { location -> SearchMatch in
                    let range = index.range(from: location.start, to: location.end)
                    let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
                    let (preview, previewRange) = makePreview(ns, line: lineRange, match: range)
                    return SearchMatch(line: location.start.line, column: location.start.character,
                                       length: range.length, preview: preview, previewRange: previewRange)
                }
            return SearchFileResult(path: path, matches: matches)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Searches every text file under `root`. `overrides` maps paths to unsaved buffer contents.
    public static func search(
        root: URL, query: String, options: SearchOptions,
        overrides: [String: String] = [:], maxMatches: Int = 5000
    ) throws -> [SearchFileResult] {
        guard !query.isEmpty else { return [] }
        let regex = try makeRegex(query, options: options)
        // Compare real paths (/private/var vs /var) so overrides line up with enumerated files.
        let root = root.canonicalFileURL
        let overrides = Dictionary(overrides.map { (URL(fileURLWithPath: $0.key).canonicalFileURL.path, $0.value) },
                                   uniquingKeysWith: { $1 })
        var results: [SearchFileResult] = []
        var total = 0
        for path in files(under: root) {
            if Task.isCancelled || total >= maxMatches { break }
            guard let text = overrides[path] ?? readText(path) else { continue }
            let found = matches(of: regex, in: text, limit: maxMatches - total)
            guard !found.isEmpty else { continue }
            total += found.count
            results.append(SearchFileResult(path: path, matches: found))
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Regular files under `root`, skipping hidden files and FileNode.ignoredNames folders.
    public static func files(under root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if FileNode.ignoredNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= maxFileSize else { continue }
            paths.append(url.path)
        }
        return paths
    }

    private static func readText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.prefix(8000).contains(0) else {
            return nil  // unreadable or binary
        }
        return String(data: data, encoding: .utf8)
    }

    private static func makePreview(_ ns: NSString, line: NSRange, match: NSRange) -> (String, NSRange) {
        var start = line.location
        var end = NSMaxRange(line)
        while end > start, [0x0A, 0x0D].contains(ns.character(at: end - 1)) { end -= 1 }
        while start < match.location, [0x20, 0x09].contains(ns.character(at: start)) { start += 1 }  // trim indent
        // Keep long lines readable: some context before the match, then cut.
        if end - start > maxPreviewLength {
            start = max(start, match.location - 40)
            end = min(end, max(start + maxPreviewLength, NSMaxRange(match)))
        }
        let preview = ns.substring(with: NSRange(location: start, length: end - start))
        let length = min(match.length, end - match.location)
        return (preview, NSRange(location: match.location - start, length: max(length, 0)))
    }
}

// MARK: - Replace

public extension ProjectSearch {
    /// The replacement template for user input: literal text unless regex mode (then `$1` etc. work).
    static func template(for replacement: String, options: SearchOptions) -> String {
        options.regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    static func replaceAll(in text: String, regex: NSRegularExpression, template: String) -> (text: String, count: Int) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        return (regex.stringByReplacingMatches(in: text, range: range, withTemplate: template), count)
    }

    /// Replaces the single match that starts at `location` (UTF-16), if it's still there.
    static func replaceMatch(in text: String, at location: Int, regex: NSRegularExpression, template: String) -> String? {
        let ns = text as NSString
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .first(where: { $0.range.location == location && $0.range.length > 0 }) else { return nil }
        let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
        return ns.replacingCharacters(in: match.range, with: replacement)
    }

    /// What a match's text becomes (for previews).
    static func preview(of matched: String, regex: NSRegularExpression, template: String) -> String {
        regex.stringByReplacingMatches(in: matched, range: NSRange(location: 0, length: (matched as NSString).length),
                                       withTemplate: template)
    }
}
