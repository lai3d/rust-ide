import Foundation

public enum GoTokenKind: Sendable, Hashable {
    case keyword, type, builtin, function, string, comment, number
}

public struct GoToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: GoTokenKind

    public init(range: NSRange, kind: GoTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A fast, regex-based Go lexer for syntax highlighting.
/// (A tree-sitter grammar can replace this later for incremental parsing.)
public enum GoHighlighter {
    public static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
        "return", "select", "struct", "switch", "type", "var",
    ]

    public static let types: Set<String> = [
        "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64",
        "int", "int8", "int16", "int32", "int64", "rune", "string",
        "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
    ]

    public static let builtins: Set<String> = [
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make",
        "max", "min", "new", "panic", "print", "println", "real", "recover",
        "true", "false", "nil", "iota",
    ]

    // Alternation order matters: comments and strings win over anything inside them.
    private static let regex = try! NSRegularExpression(pattern: [
        #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$(?![\s\S])))"#,                 // 1: comment
        #"("(?:\\.|[^"\\\n])*"?|`[^`]*`?|'(?:\\.|[^'\\\n])*'?)"#,       // 2: string / raw string / rune
        #"(\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.[\d_]*)?(?:[eE][+-]?\d+)?i?)\b)"#, // 3: number
        #"([\p{L}_][\p{L}\p{Nd}_]*)"#,                                  // 4: identifier
    ].joined(separator: "|"))

    public static func tokenize(_ text: String) -> [GoToken] {
        let ns = text as NSString
        var tokens: [GoToken] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            if match.range(at: 1).location != NSNotFound {
                tokens.append(GoToken(range: match.range, kind: .comment))
            } else if match.range(at: 2).location != NSNotFound {
                tokens.append(GoToken(range: match.range, kind: .string))
            } else if match.range(at: 3).location != NSNotFound {
                tokens.append(GoToken(range: match.range, kind: .number))
            } else {
                let word = ns.substring(with: match.range)
                if keywords.contains(word) {
                    tokens.append(GoToken(range: match.range, kind: .keyword))
                } else if types.contains(word) {
                    tokens.append(GoToken(range: match.range, kind: .type))
                } else if builtins.contains(word) {
                    tokens.append(GoToken(range: match.range, kind: .builtin))
                } else if isFollowedByParen(ns, at: NSMaxRange(match.range)) {
                    tokens.append(GoToken(range: match.range, kind: .function))
                }
            }
        }
        return tokens
    }

    private static func isFollowedByParen(_ ns: NSString, at index: Int) -> Bool {
        var i = index
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 0x28 { return true }             // (
            if c != 0x20 && c != 0x09 { return false } // space / tab
            i += 1
        }
        return false
    }
}
