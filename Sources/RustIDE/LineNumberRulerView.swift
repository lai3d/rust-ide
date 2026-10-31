import AppKit
import RustIDECore

/// Line numbers plus diagnostic/test markers for a TextKit 1 NSTextView. A plain view placed
/// beside the scroll view (not an NSRulerView: rulers overlap the clip view via content insets,
/// which confuses horizontal scrolling).
final class LineNumberRulerView: NSView {
    private weak var textView: NSTextView?
    /// Called when the width changes so the container can re-lay out.
    var onThicknessChange: (() -> Void)?
    private(set) var ruleThickness: CGFloat = 40 {
        didSet { if ruleThickness != oldValue { onThicknessChange?() } }
    }
    private var lineIndex = LineIndex("")

    struct TestMarker: Equatable {
        let name: String
        let status: TestResult.Status?
    }

    /// Test functions per zero-based line: click to run.
    var testMarkers: [Int: TestMarker] = [:] {
        didSet { if testMarkers != oldValue { needsDisplay = true } }
    }
    var onRunTest: ((String) -> Void)?
    var onToggleBreakpoint: ((Int) -> Void)?
    var onToggleFold: ((Int) -> Void)?
    var onEditCondition: ((Int) -> Void)?

    /// Zero-based lines whose breakpoints have conditions (orange tags).
    var conditionalBreakpoints: Set<Int> = [] {
        didSet { if conditionalBreakpoints != oldValue { needsDisplay = true } }
    }

    /// Foldable lines → whether they're folded (chevrons in the right column).
    var foldMarkers: [Int: Bool] = [:] {
        didSet { if foldMarkers != oldValue { needsDisplay = true } }
    }

    /// Zero-based lines with breakpoints.
    var breakpoints: Set<Int> = [] {
        didSet { if breakpoints != oldValue { needsDisplay = true } }
    }
    /// Changes against HEAD: bars at the right edge.
    var lineChanges = LineChanges() {
        didSet { if lineChanges != oldValue { needsDisplay = true } }
    }

    /// Zero-based line where the debugger is paused.
    var executionLine: Int? {
        didSet { if executionLine != oldValue { needsDisplay = true } }
    }

    /// Worst diagnostic severity per zero-based line.
    var diagnosticMarkers: [Int: Diagnostic.Severity] = [:] {
        didSet { if diagnosticMarkers != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView) {
        super.init(frame: .zero)
        self.textView = textView
        clipsToBounds = true  // macOS 14+ doesn't clip by default
        textDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override var isFlipped: Bool { true }

    private var font: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    /// Call after the text view's contents change.
    func textDidChange() {
        lineIndex = LineIndex(textView?.string ?? "")
        let digits = max(3, String(lineIndex.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 44)  // + fold column
        ruleThickness = thickness
        needsDisplay = true
    }

    /// Click the ▶ column of a test line to run it; anywhere else toggles a breakpoint.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let line = line(at: point) else { return super.mouseDown(with: event) }
        if let test = testMarkers[line], point.x < 17 {
            onRunTest?(test.name)
        } else if foldMarkers[line] != nil, point.x > bounds.maxX - 18 {
            onToggleFold?(line)
        } else {
            onToggleBreakpoint?(line)
        }
    }

    /// Right-click: breakpoint actions for the line.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let line = line(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        if breakpoints.contains(line) {
            menu.addItem(ActionMenuItem(title: "Edit Condition…") { [weak self] in self?.onEditCondition?(line) })
            menu.addItem(ActionMenuItem(title: "Remove Breakpoint") { [weak self] in self?.onToggleBreakpoint?(line) })
        } else {
            menu.addItem(ActionMenuItem(title: "Add Breakpoint") { [weak self] in self?.onToggleBreakpoint?(line) })
            menu.addItem(ActionMenuItem(title: "Add Conditional Breakpoint…") { [weak self] in self?.onEditCondition?(line) })
        }
        return menu
    }

    /// The zero-based line at a point in ruler coordinates.
    private func line(at point: NSPoint) -> Int? {
        guard let textView else { return nil }
        let inText = textView.convert(point, from: self)
        let index = textView.characterIndexForInsertion(at: NSPoint(x: 0, y: inText.y))
        return lineIndex.position(of: index).line
    }

    private func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let caretLine = lineIndex.position(of: textView.selectedRange().location).line
        let originY = textView.textContainerOrigin.y

        var lastY: CGFloat = -.greatestFiniteMagnitude
        func draw(line: Int, fragment: NSRect) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + originY), from: textView).y
            // Lines folded away share the fold line's fragment: draw only its first line.
            guard y > lastY + 0.5 else { return }
            lastY = y
            let isCaretLine = line == caretLine
            if breakpoints.contains(line) {
                // Xcode-style tag behind the line number.
                let tag = NSRect(x: 17, y: y + 1, width: bounds.width - 32, height: fragment.height - 2)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: tag.minX + 3, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX - 6, y: tag.minY))
                path.line(to: NSPoint(x: tag.maxX, y: tag.midY))
                path.line(to: NSPoint(x: tag.maxX - 6, y: tag.maxY))
                path.line(to: NSPoint(x: tag.minX + 3, y: tag.maxY))
                path.appendArc(from: NSPoint(x: tag.minX, y: tag.maxY), to: NSPoint(x: tag.minX, y: tag.midY), radius: 3)
                path.appendArc(from: NSPoint(x: tag.minX, y: tag.minY), to: NSPoint(x: tag.minX + 3, y: tag.minY), radius: 3)
                path.close()
                (conditionalBreakpoints.contains(line) ? NSColor.systemOrange : NSColor.systemBlue)
                    .withAlphaComponent(0.85).setFill()
                path.fill()
            }
            if line == executionLine {
                let arrow = NSBezierPath()
                let midY = y + fragment.height / 2
                arrow.move(to: NSPoint(x: 4, y: midY - 5))
                arrow.line(to: NSPoint(x: 11, y: midY - 5))
                arrow.line(to: NSPoint(x: 15, y: midY))
                arrow.line(to: NSPoint(x: 11, y: midY + 5))
                arrow.line(to: NSPoint(x: 4, y: midY + 5))
                arrow.close()
                NSColor.systemGreen.setFill()
                arrow.fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isCaretLine ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) : font,
                .foregroundColor: breakpoints.contains(line) ? NSColor.white
                    : isCaretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            if let change = lineChanges.lines[line] {
                (change == .added ? NSColor.systemGreen : NSColor.systemBlue).withAlphaComponent(0.8).setFill()
                NSRect(x: bounds.maxX - 4, y: y, width: 3, height: fragment.height).fill()
            }
            if lineChanges.deletions.contains(line) {
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: bounds.maxX - 6, y: y - 4))
                triangle.line(to: NSPoint(x: bounds.maxX - 1, y: y))
                triangle.line(to: NSPoint(x: bounds.maxX - 6, y: y + 4))
                triangle.close()
                NSColor.systemRed.setFill()
                triangle.fill()
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - 20 - size.width, y: y + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            if let isFolded = foldMarkers[line] {
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                    .applying(.init(paletteColors: [isFolded ? .controlAccentColor : .tertiaryLabelColor]))
                if let chevron = NSImage(systemSymbolName: isFolded ? "chevron.right" : "chevron.down",
                                         accessibilityDescription: isFolded ? "Unfold" : "Fold")?.withSymbolConfiguration(config) {
                    let s = chevron.size
                    chevron.draw(in: NSRect(x: bounds.maxX - 14, y: y + (fragment.height - s.height) / 2, width: s.width, height: s.height))
                }
            }
            if line == executionLine {
                // the arrow above owns the marker column
            } else if let test = testMarkers[line] {
                let (symbol, color): (String, NSColor) = switch test.status {
                case .passed?: ("checkmark.circle.fill", .systemGreen)
                case .failed?: ("xmark.circle.fill", .systemRed)
                case .running?: ("clock.fill", .secondaryLabelColor)
                default: ("play.fill", .systemGreen)
                }
                // Circle symbols: white glyph on a colored disc; play: just colored.
                let palette: [NSColor] = symbol.hasSuffix("circle.fill") ? [.white, color] : [color]
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                    .applying(.init(paletteColors: palette))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Run \(test.name)")?
                    .withSymbolConfiguration(config) {
                    let size = image.size
                    image.draw(in: NSRect(x: 4, y: y + (fragment.height - size.height) / 2,
                                          width: size.width, height: size.height))
                }
            } else if let severity = diagnosticMarkers[line] {
                let color: NSColor = severity == .error ? .systemRed : .systemYellow
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: y + fragment.height / 2 - 3.5, width: 7, height: 7)).fill()
            }
        }

        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var charIndex = text.length == 0 ? 0 : text.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var line = lineIndex.position(of: charIndex).line

        while charIndex < text.length && charIndex <= NSMaxRange(chars) {
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
            draw(line: line, fragment: layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            charIndex = NSMaxRange(lineRange)
            line += 1
        }
        // The empty last line after a trailing newline (or an empty document).
        if charIndex >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            draw(line: lineIndex.lineCount - 1, fragment: layoutManager.extraLineFragmentRect)
        }
    }
}
