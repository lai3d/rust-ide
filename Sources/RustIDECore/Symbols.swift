import Foundation

/// A symbol from `textDocument/documentSymbol` or `workspace/symbol`.
public struct SymbolNode: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let name: String
    /// Type/signature detail, or the container name for workspace symbols.
    public let detail: String?
    /// LSP `SymbolKind`.
    public let kind: Int
    /// Document URI (workspace symbols, or flat document symbols).
    public let uri: String?
    /// Where to put the caret: the symbol's name.
    public let position: TextPosition
    /// The whole declaration (e.g. a function including its body).
    public let rangeStart: TextPosition
    public let rangeEnd: TextPosition
    /// `nil` when there are none, so outline views show no disclosure triangle.
    public let children: [SymbolNode]?

    public init(name: String, detail: String? = nil, kind: Int, uri: String? = nil,
                position: TextPosition, rangeStart: TextPosition? = nil, rangeEnd: TextPosition? = nil,
                children: [SymbolNode]? = nil) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.uri = uri
        self.position = position
        self.rangeStart = rangeStart ?? position
        self.rangeEnd = rangeEnd ?? position
        self.children = children
    }

    public func contains(_ p: TextPosition) -> Bool {
        (rangeStart.line, rangeStart.character) <= (p.line, p.character)
            && (p.line, p.character) <= (rangeEnd.line, rangeEnd.character)
    }

    /// The chain of nested symbols containing `position` (outermost first).
    public static func path(in symbols: [SymbolNode], at position: TextPosition) -> [SymbolNode] {
        guard let match = symbols.first(where: { $0.contains(position) }) else { return [] }
        return [match] + path(in: match.children ?? [], at: position)
    }

    /// Parses `DocumentSymbol[]` (hierarchical) or `SymbolInformation[]` / `WorkspaceSymbol[]` (flat).
    public static func parseAll(_ result: JSONValue) -> [SymbolNode] {
        (result.arrayValue ?? []).compactMap(parse)
    }

    private static func parse(_ value: JSONValue) -> SymbolNode? {
        guard let name = value["name"]?.stringValue, let kind = value["kind"]?.intValue else { return nil }
        // DocumentSymbol: selectionRange/range + children. SymbolInformation: location.{uri,range}.
        let location = value["location"]
        let range = value["selectionRange"] ?? value["range"] ?? location?["range"]
        let position = TextPosition(json: range?["start"]) ?? TextPosition(line: 0, character: 0)
        let full = value["range"] ?? location?["range"]
        let children = value["children"]?.arrayValue?.compactMap(parse)
        return SymbolNode(
            name: name,
            detail: value["detail"]?.stringValue ?? value["containerName"]?.stringValue,
            kind: kind,
            uri: location?["uri"]?.stringValue,
            position: position,
            rangeStart: TextPosition(json: full?["start"]),
            rangeEnd: TextPosition(json: full?["end"]),
            children: (children?.isEmpty ?? true) ? nil : children)
    }
}

public extension FuzzyMatch {
    /// Scores `candidate` against `pattern` (higher is better), or nil if it doesn't match.
    /// Rewards matches at word starts (after / _ . - or a lower→upper case change) and runs
    /// of consecutive characters; penalizes long candidates slightly.
    static func score(_ pattern: String, _ candidate: String) -> Int? {
        let p = Array(pattern.lowercased()), c = Array(candidate), lower = Array(candidate.lowercased())
        guard !p.isEmpty else { return 0 }
        var score = 0, pi = 0, previous = -2
        for (ci, ch) in lower.enumerated() where pi < p.count && ch == p[pi] {
            let atWordStart = ci == 0 || "/_.- ".contains(c[ci - 1])
                || (c[ci - 1].isLowercase && c[ci].isUppercase)
            score += 1
            if atWordStart { score += 8 }
            if ci == previous + 1 { score += 5 }
            if ci == 0 { score += 4 }
            previous = ci
            pi += 1
        }
        guard pi == p.count else { return nil }
        return score * 10 - candidate.count
    }

    /// Scores a file path: the file name counts double, so `gre` finds `greet.go` before `progress/x.go`.
    static func scorePath(_ pattern: String, _ relativePath: String) -> Int? {
        let name = (relativePath as NSString).lastPathComponent
        let nameScore = score(pattern, name).map { $0 * 2 }
        let pathScore = score(pattern, relativePath)
        switch (nameScore, pathScore) {
        case let (n?, p?): return max(n, p)
        case let (n?, nil): return n
        case let (nil, p?): return p
        default: return nil
        }
    }
}
