import Foundation

/// A single replacement plus where the selection should end up (UTF-16).
public struct TextChange: Sendable, Hashable {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// Line-oriented editing commands (pure functions over the text and selection).
public enum TextEditing {
    /// The full lines the selection touches (a selection ending at a line start excludes that line).
    public static func lineRange(in text: NSString, selection: NSRange) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length, text.character(at: end - 1) == 0x0A {
            end -= 1
        }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(end, selection.location), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    private static func lines(_ block: String) -> (lines: [String], trailingNewline: Bool) {
        let trailing = block.hasSuffix("\n")
        var parts = block.components(separatedBy: "\n")
        if trailing { parts.removeLast() }
        return (parts, trailing)
    }

    /// Adds `// ` at the common indentation of the selected lines, or removes it if all are commented.
    public static func toggleComment(in text: String, selection: NSRange) -> TextChange {
        let ns = text as NSString
        let range = lineRange(in: ns, selection: selection)
        let (lines, trailing) = lines(ns.substring(with: range))
        let indent: (String) -> Int = { line in line.prefix { $0 == "\t" || $0 == " " }.count }
        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let commented = !nonBlank.isEmpty && nonBlank.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let column = nonBlank.map(indent).min() ?? 0
        var delta = 0
        let result = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if commented {
                let at = line.index(line.startIndex, offsetBy: indent(line))
                var rest = line[at...].dropFirst(2)
                if rest.first == " " { rest = rest.dropFirst() }
                let new = String(line[..<at]) + rest
                delta += new.utf16.count - line.utf16.count
                return new
            }
            let at = line.index(line.startIndex, offsetBy: column)
            delta += 3
            return String(line[..<at]) + "// " + line[at...]
        }
        let replacement = result.joined(separator: "\n") + (trailing ? "\n" : "")
        let newSelection = selection.length == 0
            ? NSRange(location: max(range.location, selection.location + (commented ? max(delta, -selection.location) : 3)), length: 0)
            : NSRange(location: range.location, length: (replacement as NSString).length - (trailing ? 1 : 0))
        return TextChange(range: range, replacement: replacement, selection: newSelection)
    }

    /// Indents (adds a tab) or outdents (removes a tab or up to four spaces) the selected lines.
    public static func shiftLines(in text: String, selection: NSRange, outdent: Bool) -> TextChange {
        let ns = text as NSString
        let range = lineRange(in: ns, selection: selection)
        let (lines, trailing) = lines(ns.substring(with: range))
        var firstDelta = 0
        let result = lines.enumerated().map { index, line -> String in
            var new = line
            if outdent {
                if new.hasPrefix("\t") {
                    new.removeFirst()
                } else {
                    new = String(new.dropFirst(min(4, new.prefix { $0 == " " }.count)))
                }
            } else if !line.isEmpty {
                new = "\t" + line
            }
            if index == 0 { firstDelta = new.utf16.count - line.utf16.count }
            return new
        }
        let replacement = result.joined(separator: "\n") + (trailing ? "\n" : "")
        let selectionResult = selection.length == 0
            ? NSRange(location: max(range.location, selection.location + firstDelta), length: 0)
            : NSRange(location: range.location, length: (replacement as NSString).length - (trailing ? 1 : 0))
        return TextChange(range: range, replacement: replacement, selection: selectionResult)
    }

    /// Duplicates the selected lines below themselves; the selection moves to the copy.
    public static func duplicateLines(in text: String, selection: NSRange) -> TextChange {
        let ns = text as NSString
        var range = lineRange(in: ns, selection: selection)
        let block = ns.substring(with: range)
        // The last line has no newline: put one before the copy instead.
        let copy = block.hasSuffix("\n") ? block : "\n" + block
        range = NSRange(location: NSMaxRange(range), length: 0)
        return TextChange(range: range, replacement: copy,
                          selection: NSRange(location: selection.location + (copy as NSString).length, length: selection.length))
    }

    /// Moves the selected lines up or down by one line; nil at the start/end of the file.
    public static func moveLines(in text: String, selection: NSRange, up: Bool) -> TextChange? {
        let ns = text as NSString
        let range = lineRange(in: ns, selection: selection)
        var block = ns.substring(with: range)
        if up {
            guard range.location > 0 else { return nil }
            let previous = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
            var above = ns.substring(with: previous)
            let shift = (above as NSString).length  // the block moves up by the line above
            if !block.hasSuffix("\n") {  // the block is the last line: keep newlines balanced
                block += "\n"
                above.removeLast()
            }
            return TextChange(range: NSRange(location: previous.location, length: NSMaxRange(range) - previous.location),
                              replacement: block + above,
                              selection: NSRange(location: selection.location - shift, length: selection.length))
        }
        guard NSMaxRange(range) < ns.length else { return nil }
        let next = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
        var below = ns.substring(with: next)
        if !below.hasSuffix("\n") {  // moving below what was the last line
            below += "\n"
            block.removeLast()
        }
        return TextChange(range: NSRange(location: range.location, length: NSMaxRange(next) - range.location),
                          replacement: below + block,
                          selection: NSRange(location: selection.location + (below as NSString).length, length: selection.length))
    }

    // MARK: Auto-closing pairs

    public static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`", "'": "'"]

    /// Whether typing `opening` at `offset` should also insert its closer.
    public static func shouldAutoClose(_ opening: Character, in text: NSString, at offset: Int) -> Bool {
        guard pairs[opening] != nil else { return false }
        let next: unichar? = offset < text.length ? text.character(at: offset) : nil
        let nextOK = next.map { c in [0x20, 0x09, 0x0A, 0x0D, 0x29, 0x5D, 0x7D, 0x2C, 0x3B].contains(c) } ?? true
        guard nextOK else { return false }
        if opening == "\"" || opening == "'" || opening == "`" {
            // Not right after a word character (e.g. the closing quote of "abc").
            if offset > 0 {
                let previous = text.character(at: offset - 1)
                if GoIdentifier.isIdentifier(previous) || previous == unichar(opening.unicodeScalars.first!.value) { return false }
            }
        }
        return true
    }
}
