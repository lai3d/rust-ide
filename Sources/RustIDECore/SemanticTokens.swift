import Foundation

/// rust-analyzer settings RustIDE relies on (sent as initializationOptions and
/// answered for workspace/configuration section "rust-analyzer").
public enum RustAnalyzerSettings {
    /// UserDefaults key: the command rust-analyzer runs on save ("check" or "clippy").
    public static let checkCommandKey = "checkCommand"
    public static let checkCommands = ["check", "clippy"]

    public static let `default` = make()

    /// The settings with the user's choices from UserDefaults, plus a project's enabled features.
    public static func current(features: [String] = []) -> JSONValue {
        make(checkCommand: UserDefaults.standard.string(forKey: checkCommandKey) ?? "check", features: features)
    }

    /// `features`: `package/feature` keys passed to cargo (`cargo.features`) when rust-analyzer
    /// loads the workspace and runs check, so `#[cfg(feature = …)]` code is analyzed.
    public static func make(checkCommand: String = "check", features: [String] = []) -> JSONValue {
        [
            "inlayHints": [
                "typeHints": ["enable": true],
                "parameterHints": ["enable": true],
                "chainingHints": ["enable": true],
                "closingBraceHints": ["enable": false],
                "lifetimeElisionHints": ["enable": "never"],
            ],
            "completion": ["callable": ["snippets": "fill_arguments"]],  // calls get parameter placeholders
            // `cargo check` or `cargo clippy` on save; --all-targets so tests and examples are checked too.
            "check": ["command": .string(checkCommands.contains(checkCommand) ? checkCommand : "check"), "allTargets": true],
            "cargo": ["buildScripts": ["enable": true], "features": .array(features.map { .string($0) })],
            "procMacro": ["enable": true],
            "semanticHighlighting": ["strings": ["enable": false]],  // the lexer colors strings
        ]
    }
}

public extension Notification.Name {
    /// Posted when a setting sent to rust-analyzer changes; workspaces push the new configuration.
    static let rustAnalyzerSettingsChanged = Notification.Name("RustAnalyzerSettingsChanged")
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
