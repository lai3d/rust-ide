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
        style.defaultTabInterval = spaceWidth * CGFloat(settings.tabWidth)  // gofmt uses tabs
        return style
    }

    static func baseAttributes(_ settings: EditorSettings) -> [NSAttributedString.Key: Any] {
        [.font: font(settings), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle(settings)]
    }

    /// Colors for what only gopls knows (the regex lexer handles keywords, strings, …).
    static func color(forSemantic type: String, modifiers: Set<String>) -> NSColor? {
        switch type {
        case "namespace": .secondaryLabelColor  // package qualifiers: fmt.Println
        case "type", "typeParameter", "struct", "interface", "class", "enum": .systemTeal
        case "parameter": .systemBrown
        case "function" where modifiers.contains("defaultLibrary"): .systemPurple  // len, append, …
        case "function", "method": .systemBlue
        case "variable" where modifiers.contains("defaultLibrary"): .systemPurple  // nil, true, false
        case "variable" where modifiers.contains("readonly"), "enumMember": .systemIndigo  // constants
        default: nil
        }
    }

    // System colors adapt to light and dark mode automatically.
    static func color(for kind: GoTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .type: .systemTeal
        case .builtin: .systemPurple
        case .function: .systemBlue
        case .string: .systemOrange
        case .number: .systemIndigo
        case .comment: .systemGreen
        }
    }
}
