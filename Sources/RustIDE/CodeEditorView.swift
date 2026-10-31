import AppKit
import RustIDECore
import SwiftUI

/// Language-server hooks the editor calls into. Offsets are UTF-16 offsets in the buffer.
struct EditorServices {
    var completions: @MainActor (Int) async -> [CompletionItem]
    var hover: @MainActor (Int) async -> String?
    var signatureHelp: @MainActor (Int) async -> SignatureHelp?
    var highlights: @MainActor (Int) async -> [DocumentHighlight]
    var inlayHints: @MainActor () async -> [InlayHint]
    var semanticTokens: @MainActor () async -> [SemanticToken]
    var blame: @MainActor (Int) async -> BlameLine?
    var foldingRanges: @MainActor () async -> [FoldRegion]
    var definition: @MainActor (Int) -> Void
    var references: @MainActor (Int) -> Void
    var callHierarchy: @MainActor (Int) -> Void
    var implementation: @MainActor (Int) -> Void
    var typeDefinition: @MainActor (Int) -> Void
    var rename: @MainActor (Int) -> Void
    var expandMacro: @MainActor (Int) -> Void
    var codeActions: @MainActor (_ offset: Int, _ length: Int) async -> [CodeAction]
    var performAction: @MainActor (CodeAction) -> Void
    var runTest: @MainActor (String) -> Void
    var toggleBreakpoint: @MainActor (Int) -> Void
    var editBreakpointCondition: @MainActor (Int) -> Void
    /// Debugger value of an expression (nil unless paused).
    var evaluate: @MainActor (String) async -> String?
    var caretMoved: @MainActor (Int) -> Void
}

/// An NSTextView-based code editor with Go highlighting, diagnostics,
/// completion (type or Esc), hover info, and ⌘-click go-to-definition.
struct CodeEditorView: NSViewRepresentable {
    var text: String
    var highlightRust: Bool
    /// Module path of the file (`net::http`) for full test names; nil hides test markers.
    var testPathPrefix: String?
    var testStatuses: [String: TestResult.Status] = [:]
    var breakpoints: Set<Int> = []
    var conditionalBreakpoints: Set<Int> = []
    var executionLine: Int?
    var coverageLines: [Int: Bool] = [:]
    var isEditable: Bool
    var isActive: Bool
    var settings = EditorSettings()
    var showInlayHints = true
    var languageServerEpoch = 0
    /// The file at HEAD, for change bars (nil: untracked or not in Git).
    var gitBase: String?
    var showBlame = true
    var diagnostics: [Diagnostic]
    var reveal: RevealTarget?
    var quickFixRequest = 0
    var foldRequest: FoldRequest?
    var editRequest: EditRequest?
    var services: EditorServices
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let big = CGFloat.greatestFiniteMagnitude
        // TextKit 1: stable line-fragment APIs for the gutter and current-line highlight.
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: big, height: big)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true  // no soft wrap: code scrolls horizontally
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: big, height: big)

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        context.coordinator.applySettings(to: textView)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.isEditable = isEditable

        let coordinator = context.coordinator
        textView.onMouseMoved = { [weak coordinator] index in coordinator?.mouseMoved(to: index) }
        textView.onMouseExited = { [weak coordinator] in coordinator?.endHover() }
        textView.onMouseDown = { [weak coordinator] in coordinator?.dismissPopups() }
        textView.onCommandClick = { [weak coordinator] index in coordinator?.commandClick(at: index) }
        textView.contextItems = { [weak coordinator] offset in coordinator?.contextMenuItems(at: offset) ?? [] }

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        let ruler = LineNumberRulerView(textView: textView)
        ruler.onRunTest = { [weak coordinator] name in coordinator?.parent.services.runTest(name) }
        ruler.onToggleBreakpoint = { [weak coordinator] line in coordinator?.parent.services.toggleBreakpoint(line) }
        ruler.onToggleFold = { [weak coordinator] line in coordinator?.toggleFold(line: line) }
        ruler.onEditCondition = { [weak coordinator] line in coordinator?.parent.services.editBreakpointCondition(line) }
        textView.layoutManager?.delegate = coordinator.foldingDelegate
        textView.onPlaceholderClick = { [weak coordinator] offset in coordinator?.unfold(at: offset) }
        let container = EditorContainerView(scrollView: scrollView, gutter: ruler)

        coordinator.textView = textView
        coordinator.ruler = ruler
        coordinator.lastQuickFixRequest = quickFixRequest
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        ruler.textDidChange()
        coordinator.applyStyling()
        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let scrollView = container.scrollView
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if coordinator.appliedSettings != settings {
            coordinator.applySettings(to: textView)
            coordinator.applyStyling()
        }
        if coordinator.isActive != isActive {
            container.isHidden = !isActive
            if isActive {
                if let window = textView.window {
                    window.makeFirstResponder(textView)
                    coordinator.isActive = true
                }  // else: retry on the next update, once in a window
            } else {
                coordinator.dismissPopups()
                coordinator.isActive = false
            }
        }

        if textView.string != text {
            // Changed programmatically (format, rename, reload); typing never gets here.
            coordinator.applyExternalChange(text)
        } else if coordinator.appliedDiagnostics != diagnostics || coordinator.appliedHighlightRust != highlightRust {
            coordinator.applyStyling()
            coordinator.scheduleInlayHints(after: .milliseconds(150))  // gopls re-checked the file
        }
        if coordinator.appliedShowInlayHints != showInlayHints || coordinator.appliedEpoch != languageServerEpoch {
            coordinator.appliedShowInlayHints = showInlayHints
            coordinator.appliedEpoch = languageServerEpoch
            coordinator.scheduleInlayHints(after: .milliseconds(300))
        }
        coordinator.updateTestMarkers()
        if coordinator.appliedGitBase != gitBase || coordinator.appliedShowBlame != showBlame {
            coordinator.appliedGitBase = gitBase
            coordinator.appliedShowBlame = showBlame
            coordinator.scheduleLineChanges(after: .zero)
            coordinator.scheduleBlame()
        }
        if let ruler = coordinator.ruler {
            if ruler.breakpoints != breakpoints { ruler.breakpoints = breakpoints }
            if ruler.conditionalBreakpoints != conditionalBreakpoints { ruler.conditionalBreakpoints = conditionalBreakpoints }
            if ruler.executionLine != executionLine { ruler.executionLine = executionLine }
        }
        if textView.executionLine != executionLine { textView.executionLine = executionLine }
        if textView.coverageLines != coverageLines { textView.coverageLines = coverageLines }

        if let editRequest, editRequest.id != coordinator.lastEditRequestID {
            coordinator.lastEditRequestID = editRequest.id
            if isActive { coordinator.perform(editRequest.action) }
        }

        if let foldRequest, foldRequest.id != coordinator.lastFoldRequestID {
            coordinator.lastFoldRequestID = foldRequest.id
            if isActive { coordinator.perform(foldRequest.action) }
        }

        if quickFixRequest != coordinator.lastQuickFixRequest {
            coordinator.lastQuickFixRequest = quickFixRequest
            if isActive { coordinator.showQuickFixes() }
        }

        if let reveal, reveal.id != coordinator.lastRevealID {
            coordinator.lastRevealID = reveal.id
            coordinator.performReveal(reveal, in: scrollView)
        }
    }

    static func dismantleNSView(_ container: EditorContainerView, coordinator: Coordinator) {
        coordinator.dismissPopups()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: CodeTextView?
        weak var ruler: LineNumberRulerView?
        var appliedDiagnostics: [Diagnostic] = []
        var appliedHighlightRust = false
        var lastRevealID: UUID?
        var lastQuickFixRequest = 0
        var lastFoldRequestID: UUID?
        var lastEditRequestID: UUID?
        var isActive: Bool?

        private let completionPopup = CompletionPopup()
        private var completionItems: [CompletionItem] = []
        private var completionTask: Task<Void, Never>?
        private var lastReplacement: String?
        private var isApplyingCompletion = false
        private var isApplyingExternalChange = false

        private let signaturePopup = SignaturePopup()
        private var signatureTask: Task<Void, Never>?

        private var hoverTask: Task<Void, Never>?
        private var hoverWord: NSRange?
        private var hoverPopover: NSPopover?

        init(_ parent: CodeEditorView) {
            self.parent = parent
            super.init()
            completionPopup.onAccept = { [weak self] item in self?.accept(item) }
        }

        // MARK: Text changes

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if !isApplyingCommand, let handled = handleAutoPair(textView, range: range, replacement: replacementString) {
                return handled
            }
            lastReplacement = replacementString
            pendingEdit = (range, (replacementString?.utf16.count ?? 0) - range.length)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            ruler?.textDidChange()
            shiftInlayHints()
            applyStyling()
            scheduleInlayHints(after: .milliseconds(600))
            scheduleLineChanges(after: .milliseconds(250))
            endHover()
            clearOccurrences()  // stale after an edit; the selection change re-requests

            let typed = lastReplacement
            lastReplacement = nil
            if let closer = pendingCloser {  // auto-close: insert the closer after the caret
                pendingCloser = nil
                let caret = textView.selectedRange().location
                isApplyingCommand = true
                // Our own insertion bypasses shouldChange: shift enclosing pairs (and stops) by hand.
                shiftAutoPairs(for: NSRange(location: caret, length: 0), inserted: closer.utf16.count)
                textView.insertText(closer, replacementRange: NSRange(location: caret, length: 0))
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                isApplyingCommand = false
                autoPairs.append(AutoPair(open: caret - 1, close: caret))
            }
            guard parent.highlightRust, !isApplyingCompletion, !isApplyingExternalChange, !isApplyingCommand else { return }

            // Parameter hints: open on "(" / ",", follow edits while open.
            if typed == "(" || typed == "," {
                scheduleSignatureHelp(after: .zero)
            } else if signaturePopup.isVisible {
                scheduleSignatureHelp(after: .milliseconds(80))
            }

            if let typed, typed.utf16.count == 1, let unit = typed.utf16.first,
               unit == 0x2E || GoIdentifier.isIdentifier(unit) {
                if unit == 0x2E {  // "." starts a fresh member completion
                    completionItems = []
                    completionPopup.hide()
                    scheduleCompletion(after: .zero)
                } else {
                    refilterCompletions()
                    scheduleCompletion(after: .milliseconds(80))
                }
            } else if typed == "", completionPopup.isVisible {
                refilterCompletions()
                scheduleCompletion(after: .milliseconds(80))
            } else {
                hideCompletions()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.services.caretMoved(textView.selectedRange().location)
            ruler?.needsDisplay = true
            // Leaving a pair (caret outside opener…closer) forgets it — but not while we're
            // inserting text ourselves (the caret passes through intermediate positions).
            let caret = textView.selectedRange().location
            if !isApplyingCommand {
                if let first = snippetStops.first, let last = snippetStops.last,
                   caret < first.location || caret > NSMaxRange(last) {
                    endSnippetSession()
                }
                autoPairs.removeAll { caret <= $0.open || caret > $0.close }
            }
            if let fold = folded.first(where: { caret > $0.location && caret < NSMaxRange($0) }) {
                setFolded(folded.filter { $0 != fold })  // the caret went inside: open it
            }
            if signaturePopup.isVisible { scheduleSignatureHelp(after: .milliseconds(80)) }
            scheduleOccurrences()
            scheduleBlame()
        }

        // MARK: Inline blame

        private var blameTask: Task<Void, Never>?

        /// Shows who last changed the caret's line, at the end of the line.
        func scheduleBlame() {
            blameTask?.cancel()
            guard let textView, parent.showBlame, parent.gitBase != nil else {
                textView?.blame = nil
                return
            }
            let line = LineIndex(textView.string).position(of: textView.selectedRange().location).line
            if textView.blame?.line != line { textView.blame = nil }
            blameTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                let info = await self.parent.services.blame(line)
                guard !Task.isCancelled, let textView = self.textView else { return }
                textView.blame = info.map { (line, Self.describe($0)) }
            }
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter
        }()

        static func describe(_ blame: BlameLine) -> String {
            if blame.isUncommitted { return "You · Uncommitted changes" }
            let when = relativeFormatter.localizedString(for: blame.date, relativeTo: Date())
            return "\(blame.author), \(when) · \(blame.summary)"
        }

        // MARK: Folding

        /// Foldable regions from gopls: the line they start on and the range folding hides.
        private var foldRegions: [(line: Int, range: NSRange)] = []
        /// Currently folded (hidden) ranges, sorted. Mirrored into `foldingDelegate` for layout.
        private(set) var folded: [NSRange] = [] {
            didSet { foldingDelegate.folded = folded }
        }
        let foldingDelegate = FoldingLayoutDelegate()

        func isHidden(_ index: Int) -> Bool {
            folded.contains { NSLocationInRange(index, $0) }
        }

        private func line(of offset: Int) -> Int {
            LineIndex(textView?.string ?? "").position(of: offset).line
        }

        func toggleFold(line: Int) {
            if let open = folded.first(where: { self.line(of: $0.location) == line }) {
                setFolded(folded.filter { $0 != open })
            } else if let region = foldRegions.filter({ $0.line == line }).max(by: { $0.range.length < $1.range.length }) {
                setFolded(folded + [region.range])
            }
        }

        func unfold(at offset: Int) {
            setFolded(folded.filter { $0.location != offset })
        }

        func perform(_ action: FoldAction) {
            guard let textView else { return }
            let caret = textView.selectedRange().location
            let caretLine = line(of: caret)
            switch action {
            case .fold:
                // The innermost region around the caret (or starting on its line).
                let candidates = foldRegions.filter {
                    !folded.contains($0.range) && ($0.line == caretLine || NSLocationInRange(caret, $0.range))
                }
                if let region = candidates.min(by: { $0.range.length < $1.range.length }) {
                    setFolded(folded + [region.range])
                }
            case .unfold:
                setFolded(folded.filter { !(NSLocationInRange(caret, $0) || line(of: $0.location) == caretLine) })
            case .foldAll:
                setFolded(foldRegions.map(\.range))
            case .unfoldAll:
                setFolded([])
            }
            // Keep the caret visible: out of any hidden range.
            if let fold = folded.first(where: { NSLocationInRange(caret, $0) }) {
                textView.setSelectedRange(NSRange(location: fold.location, length: 0))
            }
        }

        private func setFolded(_ ranges: [NSRange]) {
            // Drop folds nested inside other folds' hidden text only for display; keep them all.
            folded = Array(Set(ranges.map { NSValue(range: $0) })).map(\.rangeValue).sorted { $0.location < $1.location }
            invalidateFolding()
            applyStyling()
        }

        private func invalidateFolding() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }

        private func updateFoldMarkers() {
            guard let ruler else { return }
            var markers: [Int: Bool] = [:]
            for region in foldRegions where markers[region.line] == nil {
                markers[region.line] = false
            }
            for fold in folded { markers[line(of: fold.location)] = true }
            ruler.foldMarkers = markers
        }

        // MARK: Git change bars

        var appliedGitBase: String??
        var appliedShowBlame: Bool?
        private var lineChangesTask: Task<Void, Never>?

        func scheduleLineChanges(after delay: Duration) {
            lineChangesTask?.cancel()
            guard let base = parent.gitBase else {
                ruler?.lineChanges = LineChanges()
                return
            }
            lineChangesTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let text = self.textView?.string else { return }
                let changes = await Task.detached(priority: .utility) { LineChanges.compute(base: base, current: text) }.value
                guard !Task.isCancelled else { return }
                self.ruler?.lineChanges = changes
            }
        }

        // MARK: Inlay hints

        struct PlacedHint {
            var offset: Int
            let label: String
            let paddingLeft: Bool
            let paddingRight: Bool
        }

        struct SemanticRun {
            var range: NSRange
            let color: NSColor
        }

        /// gopls semantic coloring, layered over the regex lexer.
        private var semanticRuns: [SemanticRun] = []
        var appliedShowInlayHints: Bool?
        var appliedEpoch: Int?
        private var placedHints: [PlacedHint] = []
        private var inlayTask: Task<Void, Never>?
        private var pendingEdit: (range: NSRange, delta: Int)?

        func scheduleInlayHints(after delay: Duration) {
            inlayTask?.cancel()
            guard parent.highlightRust else {
                if !placedHints.isEmpty || !semanticRuns.isEmpty {
                    placedHints = []
                    semanticRuns = []
                    applyStyling()
                }
                return
            }
            if !parent.showInlayHints, !placedHints.isEmpty {
                placedHints = []
                applyStyling()
            }
            inlayTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let text = textView.string
                async let hints = self.parent.showInlayHints ? self.parent.services.inlayHints() : []
                async let tokens = self.parent.services.semanticTokens()
                async let regions = self.parent.services.foldingRanges()
                let (newHints, newTokens, newRegions) = await (hints, tokens, regions)
                guard !Task.isCancelled, textView.string == text else { return }  // edited meanwhile
                let index = LineIndex(text)
                self.placedHints = newHints.map {
                    PlacedHint(offset: index.offset(of: $0.position), label: $0.label,
                               paddingLeft: $0.paddingLeft, paddingRight: $0.paddingRight)
                }
                let ns = text as NSString
                self.foldRegions = newRegions.compactMap { region in
                    region.hiddenRange(in: index, text: ns).map { (line: region.startLine, range: $0) }
                }
                self.semanticRuns = newTokens.compactMap { token in
                    guard let color = EditorTheme.color(forSemantic: token.type, modifiers: token.modifiers) else { return nil }
                    let start = index.offset(of: TextPosition(line: token.line, character: token.start))
                    let range = NSRange(location: start, length: token.length)
                    // gopls marks import paths ("fmt") as namespaces: keep them string-colored.
                    guard NSMaxRange(range) <= ns.length, ns.character(at: start) != 0x22 else { return nil }
                    return SemanticRun(range: range, color: color)
                }
                self.applyStyling()
            }
        }

        /// Keeps existing hints attached to their text while typing (until fresh ones arrive).
        private func shiftInlayHints() {
            guard let edit = pendingEdit else { return }
            pendingEdit = nil
            let end = NSMaxRange(edit.range)
            placedHints = placedHints.compactMap { hint in
                var hint = hint
                if hint.offset >= end {
                    hint.offset += edit.delta
                } else if hint.offset > edit.range.location {
                    return nil  // its text was replaced
                }
                return hint
            }
            let foldCount = folded.count
            folded = folded.compactMap { range in
                var range = range
                if range.location >= end {
                    range.location += edit.delta
                } else if NSMaxRange(range) > edit.range.location {
                    return nil  // edited inside a fold: unfold it
                }
                return range
            }
            if folded.count != foldCount { invalidateFolding() }
            foldRegions = foldRegions.compactMap { region in
                var region = region
                if region.range.location >= end { region.range.location += edit.delta }
                else if NSMaxRange(region.range) > edit.range.location { return nil }
                return region
            }
            semanticRuns = semanticRuns.compactMap { run in
                var run = run
                if run.range.location >= end {
                    run.range.location += edit.delta
                } else if NSMaxRange(run.range) > edit.range.location {
                    return nil  // overlaps the edit: wait for fresh tokens
                }
                return run
            }
        }

        /// Opens a gap (kerning on the preceding character) for each hint and hands the
        /// labels to the text view, which draws them in the gaps. Text and undo are untouched.
        private func applyInlayHints(to storage: NSTextStorage, in textView: CodeTextView) {
            let ns = storage.string as NSString
            let font = NSFont.monospacedSystemFont(ofSize: max(9, parent.settings.fontSize - 2), weight: .regular)
            var items: [CodeTextView.InlayItem] = []
            var used = Set<Int>()
            // Fold placeholders first: "{⋯}"
            for fold in folded where fold.location > 0 && NSMaxRange(fold) <= ns.length {
                used.insert(fold.location)
                let label = NSAttributedString(string: "⋯", attributes: [
                    .font: NSFont.systemFont(ofSize: max(9, parent.settings.fontSize - 1), weight: .bold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let width = ceil(label.size().width) + 14
                storage.addAttribute(.kern, value: width, range: NSRange(location: fold.location - 1, length: 1))
                items.append(CodeTextView.InlayItem(offset: fold.location, label: label, width: width,
                                                    padLeft: 2, padRight: 2, isFold: true))
            }
            guard parent.highlightRust, parent.showInlayHints, !placedHints.isEmpty else {
                textView.inlayItems = items
                return
            }
            for hint in placedHints where hint.offset > 0 && hint.offset <= ns.length && !used.contains(hint.offset)
                && !isHidden(hint.offset - 1) {
                guard ns.character(at: hint.offset - 1) != 0x0A else { continue }  // no gap at a line start
                used.insert(hint.offset)
                let label = NSAttributedString(string: hint.label, attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                let padLeft: CGFloat = hint.paddingLeft ? 4 : 1
                let padRight: CGFloat = hint.paddingRight ? 4 : 1
                let width = ceil(label.size().width) + 8 + padLeft + padRight
                storage.addAttribute(.kern, value: width, range: NSRange(location: hint.offset - 1, length: 1))
                items.append(CodeTextView.InlayItem(offset: hint.offset, label: label, width: width,
                                                    padLeft: padLeft, padRight: padRight))
            }
            textView.inlayItems = items
        }

        // MARK: Occurrence highlights

        private var occurrenceTask: Task<Void, Never>?
        private var occurrenceRanges: [NSRange] = []

        /// Highlights other uses of the symbol at the caret, after a short pause.
        private func scheduleOccurrences() {
            occurrenceTask?.cancel()
            guard let textView, parent.highlightRust, textView.selectedRange().length == 0 else {
                clearOccurrences()
                return
            }
            let offset = textView.selectedRange().location
            let ns = textView.string as NSString
            // Only when the caret touches an identifier (either side of it).
            guard GoIdentifier.wordRange(in: ns, at: offset) != nil || GoIdentifier.wordRange(in: ns, at: offset - 1) != nil else {
                clearOccurrences()
                return
            }
            occurrenceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                let highlights = await self.parent.services.highlights(offset)
                guard !Task.isCancelled, let textView = self.textView, textView.selectedRange().location == offset else { return }
                self.showOccurrences(highlights, in: textView)
            }
        }

        private func showOccurrences(_ highlights: [DocumentHighlight], in textView: NSTextView) {
            clearOccurrences()
            guard highlights.count > 1, let layoutManager = textView.layoutManager else { return }
            let index = LineIndex(textView.string)
            let length = (textView.string as NSString).length
            for highlight in highlights {
                let range = index.range(from: highlight.start, to: highlight.end)
                guard NSMaxRange(range) <= length, range.length > 0 else { continue }
                let color: NSColor = highlight.kind == .write
                    ? .systemOrange.withAlphaComponent(0.28)
                    : .systemBlue.withAlphaComponent(0.16)
                // Temporary attributes: drawn by the layout manager, not part of the text or undo.
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                occurrenceRanges.append(range)
            }
        }

        private func clearOccurrences() {
            guard let layoutManager = textView?.layoutManager, !occurrenceRanges.isEmpty else { return }
            let length = (textView?.string as NSString?)?.length ?? 0
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            occurrenceRanges = []
        }

        // MARK: Keys

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if completionPopup.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    completionPopup.moveSelection(by: -1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    completionPopup.moveSelection(by: 1)
                    return true
                case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                    completionPopup.moveSelection(by: -CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                    completionPopup.moveSelection(by: CompletionPopup.visibleRows)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let item = completionPopup.selectedItem { accept(item) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    hideCompletions()
                    return true
                case #selector(NSResponder.deleteBackward(_:)):
                    return false  // keep the list open; textDidChange refilters
                default:
                    hideCompletions()
                }
            }

            if !snippetStops.isEmpty {
                switch selector {
                case #selector(NSResponder.insertTab(_:)):
                    moveSnippetStop(by: 1)
                    return true
                case #selector(NSResponder.insertBacktab(_:)):
                    moveSnippetStop(by: -1)
                    return true
                case #selector(NSResponder.cancelOperation(_:)) where !signaturePopup.isVisible:
                    endSnippetSession()
                    return true
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), signaturePopup.isVisible {
                hideSignatureHelp()
                return true
            }

            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                // Esc / ⌥Esc: show completions on demand.
                if parent.highlightRust && textView.isEditable { scheduleCompletion(after: .zero) }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                autoIndentNewline(in: textView)
                return true
            case #selector(NSResponder.insertTab(_:)) where textView.isEditable:
                insertIndent(in: textView)
                return true
            default:
                return false
            }
        }

        /// One indentation level: spaces, as rustfmt writes them.
        var indentUnit: String { String(repeating: " ", count: max(parent.settings.tabWidth, 1)) }

        /// Tab: spaces to the next tab stop, or indent every selected line.
        private func insertIndent(in textView: NSTextView) {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            if selection.length > 0, ns.substring(with: selection).contains("\n") {
                let change = TextEditing.shiftLines(in: textView.string, selection: selection, outdent: false, unit: indentUnit)
                if textView.shouldChangeText(in: change.range, replacementString: change.replacement) {
                    textView.replaceCharacters(in: change.range, with: change.replacement)
                    textView.didChangeText()
                    textView.setSelectedRange(change.selection)
                }
                return
            }
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            let column = selection.location - lineStart
            let width = max(parent.settings.tabWidth, 1)
            textView.insertText(String(repeating: " ", count: width - column % width), replacementRange: selection)
        }

        /// Keep the current line's indentation, and add a level after `{` / `(` / `[`.
        private func autoIndentNewline(in textView: NSTextView) {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let before = ns.substring(with: NSRange(location: lineRange.location,
                                                    length: selection.location - lineRange.location))
            let indent = String(before.prefix { $0 == "\t" || $0 == " " })
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            let extra = (trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[")) ? indentUnit : ""
            let next: unichar? = selection.location < ns.length ? ns.character(at: selection.location) : nil
            if !extra.isEmpty, selection.length == 0, next == 0x7D || next == 0x29 || next == 0x5D {
                // Between a pair, e.g. {|}: open a block with the closer on its own line.
                textView.insertText("\n" + indent + extra + "\n" + indent, replacementRange: selection)
                textView.setSelectedRange(NSRange(location: selection.location + 1 + (indent + extra as NSString).length, length: 0))
                return
            }
            textView.insertText("\n" + indent + extra, replacementRange: selection)
        }

        // MARK: Auto-closing pairs and line commands

        private var pendingCloser: String?
        /// Pairs we inserted (opener and closer offsets), innermost last. Typing a closer where
        /// ours sits steps over it; backspace on an empty pair deletes both.
        private struct AutoPair { var open: Int; var close: Int }
        private var autoPairs: [AutoPair] = []
        private var isApplyingCommand = false

        /// Returns false to swallow the change (handled here), nil to let it through.
        private func handleAutoPair(_ textView: NSTextView, range: NSRange, replacement: String?) -> Bool? {
            guard parent.highlightRust, let replacement else { return nil }
            let ns = textView.string as NSString
            if replacement.count == 1, let character = replacement.first, range.length == 0 {
                // Typing a closer exactly where ours sits: step over it.
                if let index = autoPairs.lastIndex(where: { $0.close == range.location }), range.location < ns.length,
                   ns.substring(with: NSRange(location: range.location, length: 1)) == replacement {
                    autoPairs.remove(at: index)
                    hideCompletions()  // a closer ends whatever was being completed
                    textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                    return false
                }
                // Electric "}": on a whitespace-only line, outdent one level first.
                if character == "}" {
                    let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
                    let before = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
                    if !before.isEmpty, before.allSatisfy({ $0 == "\t" || $0 == " " }) {
                        let outdented = before.hasSuffix("\t") ? String(before.dropLast())
                                                                : String(before.dropLast(min(indentUnit.count, before.count)))
                        let whole = NSRange(location: lineStart, length: range.location - lineStart)
                        isApplyingCommand = true
                        textView.insertText(outdented + "}", replacementRange: whole)
                        isApplyingCommand = false
                        shiftAutoPairs(for: whole, inserted: (outdented as NSString).length + 1)
                        return false
                    }
                }
                if let closer = TextEditing.pairs[character], TextEditing.shouldAutoClose(character, in: ns, at: range.location) {
                    pendingCloser = String(closer)
                }
            } else if replacement.isEmpty, range.length == 1,
                      let index = autoPairs.lastIndex(where: { $0.open == range.location && $0.close == range.location + 1 }) {
                // Backspace on an empty pair we inserted: delete both.
                autoPairs.remove(at: index)
                isApplyingCommand = true
                textView.insertText("", replacementRange: NSRange(location: range.location, length: 2))
                isApplyingCommand = false
                shiftAutoPairs(for: NSRange(location: range.location, length: 2), inserted: 0)
                return false
            }
            shiftAutoPairs(for: range, inserted: replacement.utf16.count)
            return nil
        }

        /// Keeps tracked pairs (and snippet stops) aligned with an edit; drops pairs whose characters it touches.
        private func shiftAutoPairs(for range: NSRange, inserted: Int) {
            let delta = inserted - range.length
            shiftSnippetStops(for: range, delta: delta)
            autoPairs = autoPairs.compactMap { pair in
                var pair = pair
                if NSLocationInRange(pair.open, range) || NSLocationInRange(pair.close, range) { return nil }
                if range.location <= pair.open { pair.open += delta }
                if range.location <= pair.close { pair.close += delta }
                return pair
            }
        }

        // MARK: Snippet sessions

        /// Tab stops of the snippet being filled in (absolute ranges; the last is $0).
        private var snippetStops: [NSRange] = []
        private var snippetIndex = 0

        private func startSnippetSession(_ stops: [NSRange]) {
            snippetStops = stops
            snippetIndex = 0
            textView?.setSelectedRange(stops[0])
            highlightSnippetStops()
        }

        private func moveSnippetStop(by delta: Int) {
            let next = snippetIndex + delta
            guard next >= 0 else { return }
            guard next < snippetStops.count else { return endSnippetSession() }
            snippetIndex = next
            textView?.setSelectedRange(snippetStops[next])
            if next == snippetStops.count - 1 { endSnippetSession(keepSelection: true) }  // reached $0
            else { highlightSnippetStops() }
        }

        private func endSnippetSession(keepSelection: Bool = true) {
            guard !snippetStops.isEmpty else { return }
            snippetStops = []
            highlightSnippetStops()
        }

        /// Typing inside the current stop grows it; edits before a stop move it.
        private func shiftSnippetStops(for range: NSRange, delta: Int) {
            guard !snippetStops.isEmpty else { return }
            snippetStops = snippetStops.enumerated().map { index, stop in
                var stop = stop
                if index == snippetIndex, range.location >= stop.location, NSMaxRange(range) <= NSMaxRange(stop) {
                    stop.length = max(0, stop.length + delta)
                } else if range.location < stop.location || (range.location == stop.location && index != snippetIndex) {
                    stop.location = max(0, stop.location + delta)
                }
                return stop
            }
            DispatchQueue.main.async { [weak self] in self?.highlightSnippetStops() }
        }

        /// Faint boxes behind the stops still to visit.
        private func highlightSnippetStops() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
            for (index, stop) in snippetStops.enumerated() where index > snippetIndex && stop.length > 0 && NSMaxRange(stop) <= length {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue,
                    .underlineColor: NSColor.controlAccentColor,
                ], forCharacterRange: stop)
            }
        }

        /// Runs a line command as one undoable edit.
        func perform(_ action: EditAction) {
            guard let textView, textView.isEditable else { return }
            let text = textView.string, selection = textView.selectedRange()
            let change: TextChange? = switch action {
            case .toggleComment: TextEditing.toggleComment(in: text, selection: selection)
            case .indent: TextEditing.shiftLines(in: text, selection: selection, outdent: false, unit: indentUnit)
            case .outdent: TextEditing.shiftLines(in: text, selection: selection, outdent: true, unit: indentUnit)
            case .duplicateLines: TextEditing.duplicateLines(in: text, selection: selection)
            case .moveLinesUp: TextEditing.moveLines(in: text, selection: selection, up: true)
            case .moveLinesDown: TextEditing.moveLines(in: text, selection: selection, up: false)
            }
            guard let change else { return }
            dismissPopups()
            autoPairs = []
            isApplyingCommand = true
            textView.insertText(change.replacement, replacementRange: change.range)
            isApplyingCommand = false
            textView.setSelectedRange(change.selection)
            textView.scrollRangeToVisible(change.selection)
        }

        // MARK: Completion

        private func scheduleCompletion(after delay: Duration) {
            completionTask?.cancel()
            completionTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let offset = textView.selectedRange().location
                let items = await self.parent.services.completions(offset)
                // Stale if the caret moved meanwhile (typing re-requests; other moves mean "done").
                guard !Task.isCancelled, textView.selectedRange().location == offset else { return }
                self.completionItems = items
                self.refilterCompletions()
            }
        }

        private func refilterCompletions() {
            guard let textView, let window = textView.window, !completionItems.isEmpty else {
                completionPopup.hide()
                return
            }
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let start = GoIdentifier.prefixStart(in: ns, before: caret)
            let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
            if let first = prefix.utf16.first, !GoIdentifier.isIdentifierStart(first) {
                completionPopup.hide()  // typing a number
                return
            }
            let matches = completionItems.filter { FuzzyMatch.matches(prefix, $0.filterText) }
            if matches.isEmpty || (matches.count == 1 && matches[0].insertText == prefix) {
                completionPopup.hide()
                return
            }
            endHover()
            let anchor = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            completionPopup.show(matches, below: anchor, in: window)
        }

        private func hideCompletions() {
            completionTask?.cancel()
            completionTask = nil
            completionItems = []
            completionPopup.hide()
        }

        private func accept(_ item: CompletionItem) {
            hideCompletions()
            guard let textView else { return }
            isApplyingCompletion = true
            defer { isApplyingCompletion = false }

            let caret = textView.selectedRange().location
            let ns = textView.string as NSString
            let start = GoIdentifier.prefixStart(in: ns, before: caret)
            // Snippets keep the line's indentation on their following lines.
            let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
            let indent = String(ns.substring(with: NSRange(location: lineStart, length: start - lineStart)).prefix { $0 == "\t" || $0 == " " })
            let snippet = item.snippet.map { Snippet.parse($0).indented(indent) }
            let insertion = snippet?.text ?? item.insertText
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(insertion, replacementRange: NSRange(location: start, length: caret - start))
            var newCaret = start + insertion.utf16.count
            var snippetBase = start

            // Extra edits (e.g. an auto-added import) sit above the caret; apply bottom-up.
            let index = LineIndex(textView.string)
            let extras = item.additionalEdits
                .map { (range: index.range(from: $0.start, to: $0.end), text: $0.newText) }
                .filter { NSMaxRange($0.range) <= start }
                .sorted { $0.range.location > $1.range.location }
            for edit in extras {
                textView.insertText(edit.text, replacementRange: edit.range)
                newCaret += edit.text.utf16.count - edit.range.length
                snippetBase += edit.text.utf16.count - edit.range.length  // edits above shift the snippet
            }
            textView.undoManager?.endUndoGrouping()
            if let snippet, snippet.stops.count > 1 || snippet.stops.first.map({ NSMaxRange($0) != (snippet.text as NSString).length }) == true {
                startSnippetSession(snippet.stops.map { NSRange(location: $0.location + snippetBase, length: $0.length) })
            } else {
                textView.setSelectedRange(NSRange(location: newCaret, length: 0))
            }
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// Applies a programmatic change as one undoable edit, keeping the caret's line/column.
        func applyExternalChange(_ newText: String) {
            guard let textView, let storage = textView.textStorage else { return }
            dismissPopups()
            guard let change = TextDiff.replacement(from: textView.string, to: newText) else { return }
            let caret = textView.selectedRange().location
            let caretPosition = LineIndex(textView.string).position(of: caret)

            isApplyingExternalChange = true
            defer { isApplyingExternalChange = false }
            let undoable = textView.shouldChangeText(in: change.range, replacementString: change.text)
            storage.replaceCharacters(in: change.range, with: change.text)
            if undoable {
                textView.didChangeText()
            } else {  // read-only view: just refresh
                ruler?.textDidChange()
                applyStyling()
            }

            let delta = change.text.utf16.count - change.range.length
            let newCaret: Int
            if caret <= change.range.location {
                newCaret = caret
            } else if caret >= NSMaxRange(change.range) {
                newCaret = caret + delta
            } else {
                newCaret = LineIndex(newText).offset(of: caretPosition)
            }
            textView.setSelectedRange(NSRange(location: min(max(newCaret, 0), storage.length), length: 0))
        }

        // MARK: Signature help

        private func scheduleSignatureHelp(after delay: Duration) {
            signatureTask?.cancel()
            signatureTask = Task { [weak self] in
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, let textView = self.textView else { return }
                let offset = textView.selectedRange().location
                let help = await self.parent.services.signatureHelp(offset)
                guard !Task.isCancelled, textView.selectedRange().location == offset else { return }
                guard let help, let window = textView.window else {
                    self.signaturePopup.hide()
                    return
                }
                // Anchor at the callee (`fmt.Printf`), like Xcode/VS Code, so it stays put while typing.
                let start = GoIdentifier.callStart(in: textView.string as NSString, before: offset) ?? offset
                let anchor = textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
                self.signaturePopup.show(help, above: anchor, in: window)
            }
        }

        private func hideSignatureHelp() {
            signatureTask?.cancel()
            signatureTask = nil
            signaturePopup.hide()
        }

        // MARK: Hover

        func mouseMoved(to index: Int?) {
            guard parent.highlightRust, let textView, !completionPopup.isVisible else { return }
            guard let index, let word = GoIdentifier.wordRange(in: textView.string as NSString, at: index) else {
                endHover()
                return
            }
            if word == hoverWord { return }
            endHover()
            hoverWord = word
            let ns = textView.string as NSString
            let expression = GoIdentifier.expressionRange(in: ns, at: index).map { ns.substring(with: $0) }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                // While paused in the debugger, show the value first, then the docs.
                async let docs = self.parent.services.hover(index)
                let value: String? = if let expression { await self.parent.services.evaluate(expression) } else { nil }
                let markdown = [value.map { "```go\n\(expression ?? "") = \($0)\n```" }, await docs]
                    .compactMap { $0 }.joined(separator: "\n\n---\n\n")
                guard !Task.isCancelled, self.hoverWord == word, !markdown.isEmpty else { return }
                self.showHover(markdown, for: word)
            }
        }

        func endHover() {
            hoverTask?.cancel()
            hoverTask = nil
            hoverWord = nil
            hoverPopover?.close()
            hoverPopover = nil
        }

        private func showHover(_ markdown: String, for range: NSRange) {
            guard let textView, let window = textView.window else { return }
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let viewRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            let host = NSHostingController(rootView: HoverView(markdown: markdown))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = host
            popover.show(relativeTo: viewRect, of: textView, preferredEdge: .minY)
            hoverPopover = popover
        }

        /// Selects the target and scrolls to it once the view has a real size
        /// (a freshly created editor is still zero-sized during its first update).
        func performReveal(_ reveal: RevealTarget, in scrollView: NSScrollView, attempt: Int = 0) {
            guard let textView else { return }
            guard textView.window != nil, scrollView.contentView.bounds.width > 0 else {
                if attempt < 20 {
                    DispatchQueue.main.async { [weak self, weak scrollView] in
                        guard let self, let scrollView else { return }
                        self.performReveal(reveal, in: scrollView, attempt: attempt + 1)
                    }
                }
                return
            }
            let text = textView.string as NSString
            let location = LineIndex(textView.string).offset(of: reveal.position)
            let length = max(0, min(reveal.length, text.length - location))
            let highlight = length > 0
                ? NSRange(location: location, length: length)
                : GoIdentifier.wordRange(in: text, at: location) ?? NSRange(location: location, length: 0)
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: location, length: length))
            scrollToReveal(highlight, in: scrollView)
        }

        /// Puts `range` about a third of the way down, and avoids horizontal scrolling
        /// when the line start is visible anyway.
        func scrollToReveal(_ range: NSRange, in scrollView: NSScrollView) {
            guard let textView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)  // the view may have just been unhidden
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            // The clip view extends under the line-number ruler; its content insets mark the
            // usable area, so "scrolled fully left" is x = -insets.left, not 0.
            let clip = scrollView.contentView
            let insets = clip.contentInsets
            let visible = clip.bounds
            let usableWidth = visible.width - insets.left - insets.right
            let usableHeight = visible.height - insets.top - insets.bottom
            var origin = visible.origin
            let visibleTop = visible.minY + insets.top
            if rect.minY < visibleTop || rect.maxY > visibleTop + usableHeight {
                origin.y = rect.midY - usableHeight / 3 - insets.top
            }
            origin.x = rect.maxX + 20 < usableWidth
                ? -insets.left
                : rect.maxX - usableWidth + 40 - insets.left
            let maxY = max(-insets.top, textView.frame.height - visible.height + insets.bottom)
            origin.y = min(max(-insets.top, origin.y), maxY)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: Settings

        var appliedSettings: EditorSettings?

        func applySettings(to textView: NSTextView) {
            let settings = parent.settings
            textView.font = EditorTheme.font(settings)
            textView.typingAttributes = EditorTheme.baseAttributes(settings)
            textView.defaultParagraphStyle = EditorTheme.paragraphStyle(settings)
            appliedSettings = settings
        }

        // MARK: Test markers

        private var testMarkerKey = ""

        /// ▶ / ✓ / ✗ next to #[test] functions.
        func updateTestMarkers(force: Bool = false) {
            guard let textView, let ruler else { return }
            guard let prefix = parent.testPathPrefix else {
                if !ruler.testMarkers.isEmpty { ruler.testMarkers = [:] }
                return
            }
            let tests = RustTestFinder.testFunctions(in: textView.string).map {
                (name: RustTestFinder.join(prefix, $0.path), line: $0.line)
            }
            let key = tests.map { "\($0.name)@\($0.line):\(String(describing: parent.testStatuses[$0.name]))" }.joined(separator: ",")
            guard force || key != testMarkerKey else { return }
            testMarkerKey = key
            ruler.testMarkers = Dictionary(tests.map { ($0.line, LineNumberRulerView.TestMarker(
                name: $0.name, status: parent.testStatuses[$0.name])) }, uniquingKeysWith: { a, _ in a })
        }

        // MARK: Definition & misc

        func commandClick(at index: Int) {
            dismissPopups()
            guard parent.highlightRust else { return }
            parent.services.definition(index)
        }

        /// Language actions at the top of the editor's right-click menu.
        func contextMenuItems(at offset: Int) -> [NSMenuItem] {
            guard parent.highlightRust else { return [] }
            dismissPopups()
            return [
                ActionMenuItem(title: "Jump to Definition") { [weak self] in self?.parent.services.definition(offset) },
                ActionMenuItem(title: "Jump to Implementation") { [weak self] in self?.parent.services.implementation(offset) },
                ActionMenuItem(title: "Jump to Type Definition") { [weak self] in self?.parent.services.typeDefinition(offset) },
                ActionMenuItem(title: "Find References") { [weak self] in self?.parent.services.references(offset) },
                ActionMenuItem(title: "Call Hierarchy") { [weak self] in self?.parent.services.callHierarchy(offset) },
                ActionMenuItem(title: "Rename Symbol…") { [weak self] in self?.parent.services.rename(offset) },
                ActionMenuItem(title: "Expand Macro") { [weak self] in self?.parent.services.expandMacro(offset) },
                ActionMenuItem(title: "Quick Fix…") { [weak self] in
                    DispatchQueue.main.async { self?.showQuickFixes() }  // after this menu closes
                },
            ]
        }

        /// Pops up the code actions for the caret/selection below the caret (⌥↩).
        func showQuickFixes() {
            guard let textView, parent.highlightRust else { return }
            dismissPopups()
            let selection = textView.selectedRange()
            Task { [weak self] in
                guard let self else { return }
                let actions = await self.parent.services.codeActions(selection.location, selection.length)
                guard let textView = self.textView, let window = textView.window else { return }
                let menu = NSMenu()
                menu.autoenablesItems = false
                let groups: [(String, [CodeAction])] = [
                    ("Quick Fixes", actions.filter { $0.kind == nil || $0.kind!.hasPrefix("quickfix") }),
                    ("Refactor", actions.filter { $0.kind?.hasPrefix("refactor") == true }),
                    ("Source", actions.filter {
                        guard let kind = $0.kind else { return false }
                        return !kind.hasPrefix("quickfix") && !kind.hasPrefix("refactor")
                    }),
                ]
                for (title, group) in groups where !group.isEmpty {
                    if !menu.items.isEmpty { menu.addItem(.separator()) }
                    menu.addItem(NSMenuItem.sectionHeader(title: title))
                    for action in group.sorted(by: { $0.isPreferred && !$1.isPreferred }) {
                        menu.addItem(ActionMenuItem(title: action.title) { [weak self] in
                            self?.parent.services.performAction(action)
                        })
                    }
                }
                if menu.items.isEmpty {
                    let none = NSMenuItem(title: "No Actions Available", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    menu.addItem(none)
                }
                let screen = textView.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
                let rect = textView.convert(window.convertFromScreen(screen), from: nil)
                menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: textView)
            }
        }

        func dismissPopups() {
            endHover()
            hideCompletions()
            hideSignatureHelp()
        }

        @objc func didScroll(_ notification: Notification) {
            dismissPopups()
            ruler?.needsDisplay = true  // the gutter is a sibling view: redraw to follow
        }

        // MARK: Styling

        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let fullRange = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.setAttributes(EditorTheme.baseAttributes(parent.settings), range: fullRange)
            if parent.highlightRust {
                for token in RustHighlighter.tokenize(text) {
                    storage.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
                }
                for run in semanticRuns where NSMaxRange(run.range) <= storage.length {
                    storage.addAttribute(.foregroundColor, value: run.color, range: run.range)
                }
            }
            let index = LineIndex(text)
            for diagnostic in parent.diagnostics {
                var range = index.range(from: diagnostic.start, to: diagnostic.end)
                if range.length == 0 { range.length = min(1, storage.length - range.location) }
                guard range.length > 0 else { continue }
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], range: range)
            }
            applyInlayHints(to: storage, in: textView)
            storage.endEditing()

            var markers: [Int: Diagnostic.Severity] = [:]
            for diagnostic in parent.diagnostics {
                let line = diagnostic.start.line
                if let existing = markers[line], existing.rawValue <= diagnostic.severity.rawValue { continue }
                markers[line] = diagnostic.severity
            }
            ruler?.diagnosticMarkers = markers
            updateTestMarkers(force: true)
            updateFoldMarkers()

            appliedDiagnostics = parent.diagnostics
            appliedHighlightRust = parent.highlightRust
        }
    }
}

/// NSTextView that reports hover positions and ⌘-clicks.
final class CodeTextView: NSTextView {
    var onMouseMoved: ((Int?) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    var contextItems: ((Int) -> [NSMenuItem])?
    private var hoverArea: NSTrackingArea?
    struct InlayItem {
        let offset: Int
        let label: NSAttributedString
        let width: CGFloat
        let padLeft: CGFloat
        let padRight: CGFloat
        var isFold = false
    }

    var onPlaceholderClick: ((Int) -> Void)?

    /// Inlay hint labels, drawn into the kerning gaps the coordinator opened before `offset`.
    var inlayItems: [InlayItem] = [] {
        didSet { needsDisplay = true }
    }

    /// Blame for the caret line, drawn after the line's text.
    var blame: (line: Int, text: String)? {
        didSet { if blame?.line != oldValue?.line || blame?.text != oldValue?.text { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlame(in: dirtyRect)
        drawInlayHints(in: dirtyRect)
    }

    private func drawBlame(in dirtyRect: NSRect) {
        guard let blame, let layoutManager, let textContainer, var lineRect = lineFragmentRect(forLine: blame.line) else { return }
        guard lineRect.intersects(dirtyRect) else { return }
        // End of the line's text: the used rect of its last fragment.
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: lineRect.maxX, y: lineRect.midY - textContainerOrigin.y),
                                             in: textContainer)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = NSFont.systemFont(ofSize: max(9, (self.font?.pointSize ?? 13) - 2))
        let text = NSAttributedString(string: blame.text, attributes: [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        let size = text.size()
        lineRect.origin.x = used.maxX + textContainerOrigin.x + 36
        text.draw(at: NSPoint(x: lineRect.minX, y: lineRect.midY - size.height / 2))
    }

    private func drawInlayHints(in dirtyRect: NSRect) {
        for item in inlayItems {
            guard let pill = pillRect(for: item), pill.insetBy(dx: 0, dy: -4).intersects(dirtyRect) else { continue }
            let fill = item.isFold ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                                   : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            fill.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            let size = item.label.size()
            let x = item.isFold ? pill.midX - size.width / 2 : pill.minX + 4
            item.label.draw(at: NSPoint(x: x, y: pill.midY - size.height / 2))
        }
    }

    /// Where an inlay label (or fold placeholder) sits: the kerning gap before `offset`.
    func pillRect(for item: InlayItem) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        guard item.offset > 0, item.offset <= length else { return nil }
        let origin = textContainerOrigin
        let previous = layoutManager.glyphIndexForCharacter(at: item.offset - 1)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: previous, effectiveRange: nil)
        lineRect.origin.y += origin.y
        // The gap ends where the next glyph starts.
        let gapEnd: CGFloat
        if item.offset < length {
            let next = layoutManager.glyphIndexForCharacter(at: item.offset)
            gapEnd = layoutManager.lineFragmentRect(forGlyphAt: next, effectiveRange: nil).minX
                + layoutManager.location(forGlyphAt: next).x + origin.x
        } else {
            gapEnd = layoutManager.boundingRect(forGlyphRange: NSRange(location: previous, length: 1), in: textContainer).maxX
                + origin.x
        }
        return NSRect(x: gapEnd - item.width + item.padLeft, y: lineRect.minY + 2,
                      width: item.width - item.padLeft - item.padRight, height: lineRect.height - 4)
    }

    /// Test coverage tint: zero-based line → covered.
    var coverageLines: [Int: Bool] = [:] {
        didSet { if coverageLines != oldValue { needsDisplay = true } }
    }

    /// Zero-based line where the debugger is paused (highlighted).
    var executionLine: Int? {
        didSet { if executionLine != oldValue { needsDisplay = true } }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // Right-clicking outside the selection moves the caret there first, like Xcode.
        if let index = characterIndex(atWindowPoint: event.locationInWindow),
           !NSLocationInRange(index, selectedRange()) {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        let items = contextItems?(selectedRange().location) ?? []
        for (position, item) in items.enumerated() { menu.insertItem(item, at: position) }
        if !items.isEmpty { menu.insertItem(.separator(), at: items.count) }
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true  // move the current-line highlight
    }

    /// Subtle highlight behind the caret's line; green behind the debugger's line.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCoverage(in: rect)
        if let executionLine, let fragment = lineFragmentRect(forLine: executionLine) {
            NSColor.systemGreen.withAlphaComponent(0.22).setFill()
            fragment.intersection(rect).fill()
        }
        guard selectedRange().length == 0, let layoutManager, let textContainer else { return }
        let text = string as NSString
        let location = selectedRange().location
        var lineRect: NSRect
        if text.length == 0 || (location >= text.length && text.hasSuffix("\n")) {
            guard layoutManager.extraLineFragmentTextContainer === textContainer else { return }
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, text.length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        lineRect.origin.x = 0
        lineRect.origin.y += textContainerOrigin.y
        lineRect.size.width = bounds.width
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        lineRect.intersection(rect).fill()
    }

    private func drawCoverage(in rect: NSRect) {
        guard !coverageLines.isEmpty, let layoutManager else { return }
        let text = string as NSString
        let index = LineIndex(string)
        for (line, covered) in coverageLines where line < index.lineCount {
            let start = index.lineStarts[line]
            guard start < text.length else { continue }
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                          effectiveRange: nil)
            fragment.origin.x = 0
            fragment.origin.y += textContainerOrigin.y
            fragment.size.width = bounds.width
            guard fragment.intersects(rect) else { continue }
            (covered ? NSColor.systemGreen.withAlphaComponent(0.10) : NSColor.systemRed.withAlphaComponent(0.12)).setFill()
            fragment.intersection(rect).fill()
        }
    }

    /// The full-width rect of a zero-based line, in view coordinates.
    func lineFragmentRect(forLine line: Int) -> NSRect? {
        guard let layoutManager else { return nil }
        let text = string as NSString
        var start = 0
        for _ in 0..<line {
            guard start < text.length else { return nil }
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
        }
        guard start < text.length else { return nil }
        var rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start),
                                                  effectiveRange: nil)
        rect.origin.x = 0
        rect.origin.y += textContainerOrigin.y
        rect.size.width = bounds.width
        return rect
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(characterIndex(atWindowPoint: event.locationInWindow))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let point = convert(event.locationInWindow, from: nil)
        if let fold = inlayItems.first(where: { $0.isFold && (pillRect(for: $0)?.insetBy(dx: -2, dy: -2).contains(point) ?? false) }) {
            onPlaceholderClick?(fold.offset)
            return
        }
        if event.modifierFlags.contains(.command), let index = characterIndex(atWindowPoint: event.locationInWindow) {
            setSelectedRange(NSRange(location: index, length: 0))
            onCommandClick?(index)
            return
        }
        super.mouseDown(with: event)
    }

    /// Index of the character under a window point, or nil when the point isn't over text.
    func characterIndex(atWindowPoint windowPoint: NSPoint) -> Int? {
        let length = (string as NSString).length
        guard length > 0, let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let insertion = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < length {
            let rect = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if rect.width > 0, rect.insetBy(dx: -0.5, dy: -0.5).contains(screenPoint) { return candidate }
        }
        return nil
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Gutter + scroll view side by side.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LineNumberRulerView

    init(scrollView: NSScrollView, gutter: LineNumberRulerView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onThicknessChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = gutter.ruleThickness
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        gutter.needsDisplay = true
    }
}

/// Hides folded text during layout: null glyphs, and newlines that don't break lines.
/// Not actor-bound (TextKit calls it synchronously); folded ranges are guarded by a lock.
final class FoldingLayoutDelegate: NSObject, NSLayoutManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _folded: [NSRange] = []

    var folded: [NSRange] {
        get { lock.withLock { _folded } }
        set { lock.withLock { _folded = newValue } }
    }

    private func isHidden(_ index: Int, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(index, $0) }
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
        font: NSFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
        let ranges = folded
        guard !ranges.isEmpty else { return 0 }
        var modified = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length where isHidden(characterIndexes[i], in: ranges) {
            modified[i] = .null
            changed = true
        }
        guard changed else { return 0 }
        modified.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes,
                                    font: font, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHidden(charIndex, in: folded) ? .zeroAdvancement : action
    }
}
