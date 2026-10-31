import Foundation

/// An expanded LSP snippet: plain text plus tab stops (`$1`, `${2:default}`, … then `$0`).
public struct Snippet: Sendable, Hashable {
    public let text: String
    /// UTF-16 ranges in `text`, in visiting order; the last is `$0` (or the end of the text).
    public let stops: [NSRange]

    public init(text: String, stops: [NSRange]) {
        self.text = text
        self.stops = stops
    }

    /// Parses LSP snippet syntax: `$n`, `${n}`, `${n:placeholder}` (nestable), `${n|a,b|}`
    /// (first choice), `$0`, and `\` escapes. Only the first occurrence of a stop is kept.
    public static func parse(_ snippet: String) -> Snippet {
        let chars = Array(snippet)
        var output = ""
        var length = 0  // UTF-16 length of output
        var stops: [Int: NSRange] = [:]
        var i = 0

        func append(_ c: Character) {
            output.append(c)
            length += c.utf16.count
        }

        func readNumber() -> Int? {
            var digits = ""
            while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            return Int(digits)
        }

        /// Parses until an unescaped "}" at this nesting level (consumed), or the end.
        func parseBody(untilBrace: Bool) {
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count, "$}\\,|".contains(chars[i + 1]) {
                    // Only these are escapable; any other backslash is literal (e.g. "\n" in Go strings).
                    append(chars[i + 1])
                    i += 2
                } else if untilBrace, c == "}" {
                    i += 1
                    return
                } else if c == "$", i + 1 < chars.count, chars[i + 1].isNumber {
                    i += 1
                    if let n = readNumber(), stops[n] == nil { stops[n] = NSRange(location: length, length: 0) }
                } else if c == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                    i += 2
                    guard let n = readNumber() else { append("$"); continue }
                    let start = length
                    if i < chars.count, chars[i] == ":" {
                        i += 1
                        parseBody(untilBrace: true)
                    } else if i < chars.count, chars[i] == "|" {
                        // Choices: keep the first one.
                        i += 1
                        var choice = ""
                        while i < chars.count, chars[i] != "," && chars[i] != "|" { choice.append(chars[i]); i += 1 }
                        while i < chars.count, chars[i] != "}" { i += 1 }
                        i += 1
                        choice.forEach(append)
                    } else if i < chars.count, chars[i] == "}" {
                        i += 1
                    }
                    if stops[n] == nil { stops[n] = NSRange(location: start, length: length - start) }
                } else {
                    append(c)
                    i += 1
                }
            }
        }

        parseBody(untilBrace: false)
        var ordered = stops.filter { $0.key != 0 }.sorted { $0.key < $1.key }.map(\.value)
        ordered.append(stops[0] ?? NSRange(location: length, length: 0))
        return Snippet(text: output, stops: ordered)
    }

    /// Indents every line after the first (for insertion at an indented caret).
    public func indented(_ indent: String) -> Snippet {
        guard !indent.isEmpty, text.contains("\n") else { return self }
        let ns = text as NSString
        let extra = (indent as NSString).length
        var newlines: [Int] = []
        for i in 0..<ns.length where ns.character(at: i) == 0x0A { newlines.append(i) }
        let shifted = stops.map { stop -> NSRange in
            let before = newlines.filter { $0 < stop.location }.count
            let inside = newlines.filter { $0 >= stop.location && $0 < NSMaxRange(stop) }.count
            return NSRange(location: stop.location + before * extra, length: stop.length + inside * extra)
        }
        return Snippet(text: text.replacingOccurrences(of: "\n", with: "\n" + indent), stops: shifted)
    }
}

/// Built-in Rust snippets, offered in completion by trigger word (rust-analyzer adds its own:
/// `tfn`, `tmod`, postfix `.if` / `.match` / `.ok` …).
public enum RustSnippets {
    public static let all: [(trigger: String, detail: String, body: String)] = [
        ("fn", "fn name(…) -> T { … }", "fn ${1:name}(${2}) ${3:-> ${4:()} }{\n    $0\n}"),
        ("pfn", "pub fn name(…) -> T { … }", "pub fn ${1:name}(${2}) ${3:-> ${4:()} }{\n    $0\n}"),
        ("main", "fn main() { … }", "fn main() {\n    $0\n}"),
        ("st", "struct Name { … }", "#[derive(Debug${1:, Clone})]\nstruct ${2:Name} {\n    $0\n}"),
        ("en", "enum Name { … }", "#[derive(Debug${1:, Clone, Copy, PartialEq, Eq})]\nenum ${2:Name} {\n    $0\n}"),
        ("impl", "impl Type { … }", "impl ${1:Type} {\n    $0\n}"),
        ("implt", "impl Trait for Type { … }", "impl ${1:Trait} for ${2:Type} {\n    $0\n}"),
        ("tr", "trait Name { … }", "trait ${1:Name} {\n    $0\n}"),
        ("match", "match … { … }", "match ${1:value} {\n    ${2:pattern} => $0,\n    _ => {}\n}"),
        ("iflet", "if let Some(x) = … { … }", "if let ${1:Some(${2:x})} = ${3:value} {\n    $0\n}"),
        ("letelse", "let Some(x) = … else { … };", "let ${1:Some(${2:x})} = ${3:value} else {\n    ${4:return};\n};$0"),
        ("whilelet", "while let Some(x) = … { … }", "while let ${1:Some(${2:x})} = ${3:iter.next()} {\n    $0\n}"),
        ("for", "for x in … { … }", "for ${1:item} in ${2:items} {\n    $0\n}"),
        ("test", "#[test] fn name() { … }", "#[test]\nfn ${1:name}() {\n    $0\n}"),
        ("modtest", "#[cfg(test)] mod tests { … }", "#[cfg(test)]\nmod tests {\n    use super::*;\n\n    #[test]\n    fn ${1:works}() {\n        $0\n    }\n}"),
        ("derive", "#[derive(…)]", "#[derive(${1:Debug, Clone})]$0"),
        ("disp", "impl fmt::Display for Type", "impl std::fmt::Display for ${1:Type} {\n    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {\n        write!(f, \"${2:{}}\", ${3:self.0})\n    }\n}$0"),
        ("from", "impl From<T> for Type", "impl From<${1:Source}> for ${2:Type} {\n    fn from(${3:value}: ${1:Source}) -> Self {\n        $0\n    }\n}"),
    ]

    /// Completion items for snippets whose trigger matches `prefix` (fuzzy, needs ≥ 2 chars).
    public static func completions(matching prefix: String) -> [CompletionItem] {
        guard prefix.count >= 2 else { return [] }
        return all.filter { FuzzyMatch.matches(prefix, $0.trigger) }.map {
            CompletionItem(label: $0.trigger, kind: .snippet, detail: $0.detail,
                           insertText: Snippet.parse($0.body).text, sortText: "~" + $0.trigger, snippet: $0.body)
        }
    }
}
