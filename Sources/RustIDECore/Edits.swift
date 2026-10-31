import Foundation

public extension TextEdit {
    /// Applies non-overlapping LSP edits (all relative to `text`) and returns the result.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let index = LineIndex(text)
        let result = NSMutableString(string: text)
        let ranged = edits.map { (range: index.range(from: $0.start, to: $0.end), text: $0.newText) }
        // Apply back to front so earlier ranges stay valid; keep server order for equal starts.
        for edit in ranged.enumerated().sorted(by: {
            ($0.element.range.location, $0.offset) > ($1.element.range.location, $1.offset)
        }).map(\.element) {
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return result as String
    }
}

/// An LSP `WorkspaceEdit`, flattened to text edits per document URI.
public struct WorkspaceEdit: Sendable, Hashable {
    public var changes: [String: [TextEdit]]
    /// Files to create (empty) before applying `changes`, e.g. a new _test.go.
    public var creates: [String]

    public init(changes: [String: [TextEdit]], creates: [String] = []) {
        self.changes = changes
        self.creates = creates
    }

    public var isEmpty: Bool { changes.values.allSatisfy(\.isEmpty) }

    /// Parses `changes` and `documentChanges` (text edits and file creation; renames/deletes are skipped).
    public static func parse(_ value: JSONValue) -> WorkspaceEdit {
        var changes: [String: [TextEdit]] = [:]
        var creates: [String] = []
        for (uri, edits) in value["changes"]?.objectValue ?? [:] {
            changes[uri, default: []] += edits.arrayValue?.compactMap(TextEdit.parse) ?? []
        }
        for change in value["documentChanges"]?.arrayValue ?? [] {
            if change["kind"]?.stringValue == "create", let uri = change["uri"]?.stringValue {
                creates.append(uri)
                continue
            }
            guard let uri = change["textDocument"]?["uri"]?.stringValue else { continue }
            changes[uri, default: []] += change["edits"]?.arrayValue?.compactMap(TextEdit.parse) ?? []
        }
        return WorkspaceEdit(changes: changes, creates: creates)
    }
}

/// An LSP `CodeAction` (or bare `Command`).
public struct CodeAction: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let kind: String?
    public let isPreferred: Bool
    public let edit: WorkspaceEdit?
    /// A command to run via `workspace/executeCommand` (after applying `edit`, if any).
    public let command: JSONValue?
    /// The raw action, for `codeAction/resolve`.
    public let raw: JSONValue

    public static func parseAll(_ result: JSONValue) -> [CodeAction] {
        (result.arrayValue ?? []).compactMap { value in
            guard let title = value["title"]?.stringValue else { return nil }
            // A bare Command has a string "command" field; a CodeAction nests it.
            let isBareCommand = value["command"]?.stringValue != nil
            return CodeAction(
                id: UUID(),
                title: title,
                kind: value["kind"]?.stringValue,
                isPreferred: value["isPreferred"]?.boolValue ?? false,
                edit: value["edit"].map(WorkspaceEdit.parse),
                command: isBareCommand ? value : value["command"],
                raw: value)
        }
    }
}

/// The smallest single replacement that turns one string into another.
public enum TextDiff {
    public static func replacement(from old: String, to new: String) -> (range: NSRange, text: String)? {
        guard old != new else { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Don't split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let range = NSRange(location: prefix, length: a.count - prefix - suffix)
        let text = (new as NSString).substring(with: NSRange(location: prefix, length: b.count - prefix - suffix))
        return (range, text)
    }
}
