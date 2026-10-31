import AppKit
import RustIDECore

/// User-adjustable editor settings (stored in UserDefaults, edited in Settings).
struct EditorSettings: Equatable {
    static let fontSizeKey = "editorFontSize"
    static let tabWidthKey = "editorTabWidth"

    var fontSize: Double = 13
    var tabWidth: Int = 4
}

@MainActor
enum EditorTheme {
    static func font(_ settings: EditorSettings) -> NSFont {
        .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
    }

    static func paragraphStyle(_ settings: EditorSettings) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font(settings)]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(settings.tabWidth)  // tabs (rare in Rust) align to the tab width
        return style
    }

    static func baseAttributes(_ settings: EditorSettings) -> [NSAttributedString.Key: Any] {
        [.font: font(settings), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle(settings)]
    }

    /// Colors for what only rust-analyzer knows (the lexer handles keywords, strings, …).
    /// Returns nil to keep the lexer's color.
    static func color(forSemantic type: String, modifiers: Set<String>) -> NSColor? {
        switch type {
        case "namespace", "crateRoot", "toolModule": .secondaryLabelColor  // std::, crate::
        case "struct", "enum", "interface", "typeAlias", "union", "typeParameter", "builtinType",
             "type", "class", "selfTypeKeyword":
            .systemTeal
        case "parameter": .systemBrown
        case "function", "method": .systemBlue
        case "macro", "macroBang", "procMacro", "derive", "deriveHelper": .systemPurple
        case "enumMember", "const", "static", "constParameter", "boolean": .systemIndigo
        case "lifetime", "label": .systemCyan
        case "selfKeyword": .systemPink
        case "attribute", "builtinAttribute", "attributeBracket": .secondaryLabelColor
        case "variable" where modifiers.contains("static"): .systemIndigo
        default: nil
        }
    }

    // System colors adapt to light and dark mode automatically.
    static func color(for kind: RustTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .builtin: .systemIndigo
        case .function: .systemBlue
        case .string: .systemOrange
        case .number: .systemIndigo
        case .comment: .systemGreen
        case .macro: .systemPurple
        case .lifetime: .systemCyan
        case .attribute: .secondaryLabelColor
        }
    }
}
