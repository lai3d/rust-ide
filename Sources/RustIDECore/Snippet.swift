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

/// Built-in Go snippets, offered in completion by trigger word.
public enum GoSnippets {
    public static let all: [(trigger: String, detail: String, body: String)] = [
        ("iferr", "if err != nil { return … }", "if err != nil {\n\treturn ${1:err}\n}$0"),
        ("errorf", "fmt.Errorf(\"…: %w\", err)", "fmt.Errorf(\"${1:context}: %w\", ${2:err})$0"),
        ("fori", "for i := 0; i < n; i++ { … }", "for i := 0; i < ${1:n}; i++ {\n\t$0\n}"),
        ("forr", "for k, v := range … { … }", "for ${1:_}, ${2:v} := range ${3:items} {\n\t$0\n}"),
        ("func", "func name(…) … { … }", "func ${1:name}(${2}) ${3}{\n\t$0\n}"),
        ("meth", "func (r T) Name(…) … { … }", "func (${1:r} ${2:*Receiver}) ${3:Name}(${4}) ${5}{\n\t$0\n}"),
        ("main", "func main() { … }", "func main() {\n\t$0\n}"),
        ("test", "func TestName(t *testing.T) { … }", "func Test${1:Name}(t *testing.T) {\n\t$0\n}"),
        ("tt", "table-driven test", "tests := []struct {\n\tname string\n\t${1:input} ${2:string}\n\twant ${3:string}\n}{\n\t{name: \"${4:case}\"},\n}\nfor _, tt := range tests {\n\tt.Run(tt.name, func(t *testing.T) {\n\t\t$0\n\t})\n}"),
        ("sw", "switch … { case …: }", "switch ${1:x} {\ncase ${2:value}:\n\t$0\n}"),
        ("sel", "select { case …: }", "select {\ncase ${1:v} := <-${2:ch}:\n\t$0\n}"),
        ("gof", "go func() { … }()", "go func() {\n\t$0\n}()"),
        ("deferf", "defer func() { … }()", "defer func() {\n\t$0\n}()"),
        ("st", "type Name struct { … }", "type ${1:Name} struct {\n\t$0\n}"),
        ("if", "interface { … }", "type ${1:Name} interface {\n\t$0\n}"),
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
