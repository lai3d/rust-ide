import Foundation

public enum RustTokenKind: Sendable, Hashable {
    case keyword, type, builtin, function, string, comment, number, macro, lifetime, attribute
}

public struct RustToken: Sendable, Hashable {
    public let range: NSRange
    public let kind: RustTokenKind

    public init(range: NSRange, kind: RustTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A fast hand-written Rust lexer for syntax highlighting (rust-analyzer's semantic
/// tokens refine it). Handles what regexes can't: nested block comments, raw strings
/// (`r#"…"#`), and lifetimes vs. char literals. Works on UTF-16 offsets like NSString.
public enum RustHighlighter {
    public static let keywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
        "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
        "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "union",
        "unsafe", "use", "where", "while", "yield", "gen", "try", "macro_rules",
    ]

    public static let types: Set<String> = [
        "bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize",
        "u8", "u16", "u32", "u64", "u128", "usize", "f16", "f32", "f64", "f128",
    ]

    public static let builtins: Set<String> = ["Some", "None", "Ok", "Err"]

    public static func tokenize(_ text: String) -> [RustToken] {
        var scanner = Scanner(Array(text.utf16))
        return scanner.run()
    }

    private struct Scanner {
        let s: [UInt16]
        var i = 0
        var tokens: [RustToken] = []

        init(_ s: [UInt16]) { self.s = s }

        func at(_ k: Int) -> UInt16 { k < s.count ? s[k] : 0 }

        mutating func emit(_ start: Int, _ kind: RustTokenKind) {
            tokens.append(RustToken(range: NSRange(location: start, length: i - start), kind: kind))
        }

        static func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c > 0x7F
        }

        static func isIdentContinue(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }
        static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func run() -> [RustToken] {
            while i < s.count {
                let c = s[i], n = at(i + 1)
                let start = i
                switch c {
                case 0x2F where n == 0x2F:  // //
                    while i < s.count, s[i] != 0x0A { i += 1 }
                    emit(start, .comment)
                case 0x2F where n == 0x2A:  // /* nested */
                    blockComment()
                    emit(start, .comment)
                case 0x23 where n == 0x5B || (n == 0x21 && at(i + 2) == 0x5B):  // #[ / #![
                    attribute()
                    emit(start, .attribute)
                case 0x22:  // "
                    i += 1
                    quoted(0x22)
                    emit(start, .string)
                case 0x27:  // ' — char literal or lifetime/label
                    charOrLifetime()
                case _ where Self.isDigit(c):
                    number()
                    emit(start, .number)
                case _ where Self.isIdentStart(c):
                    identifierOrPrefixedLiteral()
                default:
                    i += 1
                }
            }
            return tokens
        }

        mutating func blockComment() {
            i += 2
            var depth = 1
            while i < s.count, depth > 0 {
                if s[i] == 0x2F, at(i + 1) == 0x2A { depth += 1; i += 2 }
                else if s[i] == 0x2A, at(i + 1) == 0x2F { depth -= 1; i += 2 }
                else { i += 1 }
            }
        }

        /// From `#` to the matching `]`, skipping over strings inside.
        mutating func attribute() {
            while i < s.count, s[i] != 0x5B { i += 1 }
            var depth = 0
            while i < s.count {
                let c = s[i]
                if c == 0x22 { i += 1; quoted(0x22); continue }
                if c == 0x5B { depth += 1 }
                if c == 0x5D { depth -= 1; if depth == 0 { i += 1; return } }
                if c == 0x0A && depth <= 1 && at(i + 1) == 0x0A { return }  // unterminated: stop at a blank line
                i += 1
            }
        }

        /// After the opening quote: up to and including the closing one (escapes skipped).
        mutating func quoted(_ quote: UInt16) {
            while i < s.count {
                let c = s[i]
                if c == 0x5C { i += 2; continue }  // backslash escape
                i += 1
                if c == quote { return }
                if quote == 0x27, c == 0x0A { return }  // char literals don't span lines
            }
            i = min(i, s.count)
        }

        /// At `r`: `r"…"` / `r#"…"#` (any number of #). Returns false if not a raw string.
        mutating func rawString() -> Bool {
            var k = i + 1, hashes = 0
            while at(k) == 0x23 { hashes += 1; k += 1 }
            guard at(k) == 0x22 else { return false }
            k += 1
            while k < s.count {
                if s[k] == 0x22 {
                    var h = 0
                    while h < hashes, at(k + 1 + h) == 0x23 { h += 1 }
                    if h == hashes { i = k + 1 + hashes; return true }
                }
                k += 1
            }
            i = s.count
            return true
        }

        mutating func charOrLifetime() {
            let start = i
            let n = at(i + 1)
            // 'x' (one UTF-16 unit, or a surrogate pair) or an escape → char literal.
            let width = (n >= 0xD800 && n <= 0xDBFF) ? 2 : 1
            if n == 0x5C || (n != 0 && n != 0x27 && at(i + 1 + width) == 0x27) {
                i += 1
                quoted(0x27)
                emit(start, .string)
            } else if Self.isIdentStart(n) {
                i += 1
                while i < s.count, Self.isIdentContinue(s[i]) { i += 1 }
                emit(start, .lifetime)
            } else {
                i += 1
            }
        }

        mutating func number() {
            if s[i] == 0x30, [0x78, 0x6F, 0x62].contains(at(i + 1)) {  // 0x 0o 0b
                i += 2
                while i < s.count, Self.isIdentContinue(s[i]) { i += 1 }
                return
            }
            while i < s.count, Self.isDigit(s[i]) || s[i] == 0x5F { i += 1 }
            // Fraction only if a digit follows the dot (so `1..2` and `x.0.method()` stay ranges/fields).
            if at(i) == 0x2E, Self.isDigit(at(i + 1)) {
                i += 1
                while i < s.count, Self.isDigit(s[i]) || s[i] == 0x5F { i += 1 }
            }
            if at(i) == 0x65 || at(i) == 0x45 {  // exponent
                var k = i + 1
                if at(k) == 0x2B || at(k) == 0x2D { k += 1 }
                if Self.isDigit(at(k)) {
                    i = k
                    while i < s.count, Self.isDigit(s[i]) || s[i] == 0x5F { i += 1 }
                }
            }
            while i < s.count, Self.isIdentContinue(s[i]) { i += 1 }  // suffix: u32, f64, usize
        }

        mutating func identifierOrPrefixedLiteral() {
            let start = i
            let c = s[i], n = at(i + 1)
            // Literal prefixes: b"…" b'…' br"…" c"…" cr"…" r"…" r#"…"#, raw identifiers r#name.
            if c == 0x72 || ((c == 0x62 || c == 0x63) && n == 0x72) {  // r, br, cr
                let save = i
                if c != 0x72 { i += 1 }
                if rawString() { emit(start, .string); return }
                i = save
            }
            if (c == 0x62 || c == 0x63) && n == 0x22 {  // b"…" c"…"
                i += 2
                quoted(0x22)
                emit(start, .string)
                return
            }
            if c == 0x62, n == 0x27 {  // b'x'
                i += 2
                quoted(0x27)
                emit(start, .string)
                return
            }
            if c == 0x72, n == 0x23, Self.isIdentStart(at(i + 2)) { i += 2 }  // r#ident

            while i < s.count, Self.isIdentContinue(s[i]) { i += 1 }
            let word = String(utf16CodeUnits: Array(s[start..<i]), count: i - start)
            if at(i) == 0x21, at(i + 1) != 0x3D, !RustHighlighter.keywords.contains(word) || word == "macro_rules" {  // name! (not !=)
                i += 1
                emit(start, .macro)
            } else if RustHighlighter.keywords.contains(word) {
                emit(start, .keyword)
            } else if RustHighlighter.types.contains(word) {
                emit(start, .type)
            } else if RustHighlighter.builtins.contains(word) {
                emit(start, .builtin)
            } else if isFollowedByCall(at: i) {
                emit(start, .function)
            } else if let first = word.unicodeScalars.first, first.properties.isUppercase,
                      word.contains(where: \.isLowercase) {
                emit(start, .type)  // CamelCase: types, traits, enum variants
            }
        }

        /// `name(` or turbofish `name::<…>(`.
        func isFollowedByCall(at index: Int) -> Bool {
            var k = index
            while at(k) == 0x20 || at(k) == 0x09 { k += 1 }
            if at(k) == 0x28 { return true }
            if at(k) == 0x3A, at(k + 1) == 0x3A, at(k + 2) == 0x3C {  // ::<
                var depth = 0
                k += 2
                while k < s.count {
                    if s[k] == 0x3C { depth += 1 } else if s[k] == 0x3E { depth -= 1; if depth == 0 { return at(k + 1) == 0x28 } }
                    else if s[k] == 0x0A || s[k] == 0x3B || s[k] == 0x7B { return false }
                    k += 1
                }
            }
            return false
        }
    }
}
