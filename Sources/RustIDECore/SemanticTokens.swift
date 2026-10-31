import Foundation

/// gopls settings RustIDE relies on (sent as initializationOptions and workspace/configuration).
public enum GoplsSettings {
    public static let `default`: JSONValue = [
        "hints": [
            "assignVariableTypes": true, "compositeLiteralFields": true, "constantValues": true,
            "functionTypeParameters": true, "parameterNames": true, "rangeVariableTypes": true,
        ],
        "semanticTokens": true,
        "usePlaceholders": true,  // function call completions get parameter placeholders
    ]
}

/// One decoded semantic token (`textDocument/semanticTokens/full`).
public struct SemanticToken: Sendable, Hashable {
    public let line: Int
    /// UTF-16 start column and length.
    public let start: Int
    public let length: Int
    public let type: String
    public let modifiers: Set<String>

    public init(line: Int, start: Int, length: Int, type: String, modifiers: Set<String> = []) {
        self.line = line
        self.start = start
        self.length = length
        self.type = type
        self.modifiers = modifiers
    }
}

/// The server's token legend, from `capabilities.semanticTokensProvider.legend`.
public struct SemanticTokenLegend: Sendable, Hashable {
    public let types: [String]
    public let modifiers: [String]

    public init(types: [String], modifiers: [String]) {
        self.types = types
        self.modifiers = modifiers
    }

    public init?(initializeResult: JSONValue) {
        let legend = initializeResult["capabilities"]?["semanticTokensProvider"]?["legend"]
        guard let types = legend?["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) else { return nil }
        self.init(types: types, modifiers: legend?["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    /// Decodes the relative 5-integer encoding: Δline, Δstart, length, type, modifier bits.
    public func decode(_ result: JSONValue) -> [SemanticToken] {
        let data = result["data"]?.arrayValue?.compactMap(\.intValue) ?? []
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(data.count / 5)
        var line = 0, start = 0
        var i = 0
        while i + 4 < data.count {
            let deltaLine = data[i], deltaStart = data[i + 1]
            line += deltaLine
            start = deltaLine == 0 ? start + deltaStart : deltaStart
            let typeIndex = data[i + 3], bits = data[i + 4]
            if types.indices.contains(typeIndex) {
                var mods = Set<String>()
                for (bit, name) in modifiers.enumerated() where bits & (1 << bit) != 0 { mods.insert(name) }
                tokens.append(SemanticToken(line: line, start: start, length: data[i + 2], type: types[typeIndex], modifiers: mods))
            }
            i += 5
        }
        return tokens
    }

    /// Token types/modifiers RustIDE asks for in its client capabilities.
    public static let clientTypes: [String] = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment",
        "string", "number", "regexp", "operator", "decorator", "label",
    ]
    public static let clientModifiers: [String] = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
        "modification", "documentation", "defaultLibrary",
    ]
}
