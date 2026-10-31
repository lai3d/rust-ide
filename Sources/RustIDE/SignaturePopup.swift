import AppKit
import RustIDECore

/// A small borderless panel above the caret showing the call signature,
/// with the parameter being typed in bold.
@MainActor
final class SignaturePopup {
    private let panel: NSPanel
    private let signature = NSTextField(wrappingLabelWithString: "")
    private let documentation = NSTextField(wrappingLabelWithString: "")
    private static let maxWidth: CGFloat = 640

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background

        documentation.font = .systemFont(ofSize: 11)
        documentation.textColor = .secondaryLabelColor
        documentation.maximumNumberOfLines = 3
        for field in [signature, documentation] {
            field.preferredMaxLayoutWidth = Self.maxWidth - 20
            field.isSelectable = false
        }
        let stack = NSStackView(views: [signature, documentation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows `help` just above `anchor` (screen coordinates of the caret line).
    func show(_ help: SignatureHelp, above anchor: NSRect, in window: NSWindow) {
        guard let active = help.active else { return hide() }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: active.label, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        if let range = help.activeParameterRange, NSMaxRange(range) <= text.length {
            text.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
            ], range: range)
        }
        signature.attributedStringValue = text
        let doc = active.documentation?.split(separator: "\n").first.map(String.init) ?? ""
        documentation.stringValue = doc
        documentation.isHidden = doc.isEmpty

        // Keep within the editor window: wrap to the space right of the anchor (min 360pt).
        let frame = window.frame
        let maxWidth = min(Self.maxWidth, max(360, frame.maxX - anchor.minX - 16))
        for field in [signature, documentation] { field.preferredMaxLayoutWidth = maxWidth - 20 }
        let size = panel.contentView!.fittingSize
        let width = min(maxWidth, size.width)
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.maxY + 4)
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - width - 8)
        if let screen = window.screen?.visibleFrame, origin.y + size.height > screen.maxY {
            origin.y = anchor.minY - size.height - 4  // no room above: show below
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: size.height)), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
