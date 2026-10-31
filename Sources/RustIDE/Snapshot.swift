import AppKit

/// Debug aid: renders the main window (plus popups) to a PNG off-screen — no Screen
/// Recording permission needed — then exits.
///
///     RustIDE <folder> [file…] --snapshot out.png [--snapshot-delay 4]
///         [--snapshot-search QUERY] [--snapshot-line N --snapshot-type TEXT] [--snapshot-format]
@MainActor
enum Snapshot {
    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let path = value("--snapshot") else { return }
        // Keep debug runs out of the user's recent projects and saved tabs.
        if let isolated = UserDefaults(suiteName: "RustIDE.snapshot") { SessionStore.defaults = isolated }
        let delay = value("--snapshot-delay").flatMap(Double.init) ?? 4

        Task {
            try? await Task.sleep(for: .seconds(delay))
            let workspace = Workspace.current

            if let query = value("--snapshot-search"), let workspace {
                workspace.showSearch()
                workspace.searchQuery = query
                if let replacement = value("--snapshot-replace") {
                    workspace.isReplaceVisible = true
                    workspace.replaceQuery = replacement
                }
                await workspace.performSearch()
                if let file = workspace.searchResults.first, let match = file.matches.first {
                    workspace.open(match, in: file)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let line = value("--snapshot-line").flatMap(Int.init),
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Caret at the end of 1-based `line`.
                let ns = textView.string as NSString
                var start = 0
                for _ in 1..<max(line, 1) {
                    start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
                }
                let lineRange = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
                var end = NSMaxRange(lineRange)
                if end > lineRange.location, end <= ns.length, ns.character(at: end - 1) == 0x0A { end -= 1 }
                if let column = value("--snapshot-column").flatMap(Int.init) {
                    end = min(lineRange.location + column, end)  // 0-based column
                }
                textView.setSelectedRange(NSRange(location: end, length: 0))
                try? await Task.sleep(for: .milliseconds(900))  // let caret-driven requests land
            }
            if let text = value("--snapshot-type"),
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Type like a user would (exercises completion / signature triggers).
                for character in text {
                    if character == "\n" {  // like pressing Return: goes through the editor's command handling
                        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    } else if character == "\t" {  // Tab: accepts completions, moves between snippet stops
                        try? await Task.sleep(for: .milliseconds(900))  // let completions arrive first
                        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
                    } else {
                        textView.insertText(String(character), replacementRange: textView.selectedRange())
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
            if let column = value("--snapshot-references").flatMap(Int.init), let workspace,
               let document = workspace.activeDocument,
               let textView = NSApp.windows.first?.firstResponder as? NSTextView {
                // Caret is at the end of --snapshot-line; step back to the given 0-based column.
                let ns = textView.string as NSString
                let lineStart = ns.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)).location
                await workspace.findReferences(in: document, at: lineStart + column)
                try? await Task.sleep(for: .milliseconds(400))
            }
            if let query = value("--snapshot-quickopen"), let workspace {
                workspace.showQuickOpen()
                try? await Task.sleep(for: .milliseconds(200))
                workspace.quickOpenQuery = query
                try? await Task.sleep(for: .milliseconds(900))
            }
            if args.contains("--snapshot-outline"), let workspace {
                workspace.sidebarMode = .outline
                try? await Task.sleep(for: .milliseconds(1200))
            }
            if args.contains("--snapshot-tests"), let workspace {
                workspace.runTests(.all, coverage: args.contains("--snapshot-coverage"))
                for _ in 0..<150 where workspace.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let lines = value("--snapshot-debug"), let workspace, let document = workspace.activeDocument {
                // Comma-separated one-based breakpoint lines in the active file, then debug and wait to pause.
                for line in lines.split(separator: ",").compactMap({ Int($0) }) {
                    workspace.toggleBreakpoint(in: document, line: line - 1)
                }
                if let condition = value("--snapshot-condition"), let line = lines.split(separator: ",").first.flatMap({ Int($0) }) {
                    workspace.setBreakpointConditionForTesting(condition, in: document, line: line - 1)
                }
                workspace.startDebugging()
                for _ in 0..<200 where workspace.debugSession?.state != .stopped {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                for watch in (value("--snapshot-watch") ?? "").split(separator: ",") {
                    workspace.debugSession?.addWatch(String(watch))
                }
                if let steps = value("--snapshot-steps").flatMap(Int.init) {
                    for _ in 0..<steps {
                        workspace.debugSession?.stepOver()
                        for _ in 0..<50 where workspace.debugSession?.state != .stopped {
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
            if let direction = value("--snapshot-calls"), let workspace, let document = workspace.activeDocument {
                await workspace.showCallHierarchy(in: document, at: document.caretOffset)
                if direction == "out" { await workspace.setCallDirection(.outgoing) }
                if let first = workspace.callRoot?.children?.first { await workspace.expand(first) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let folder = value("--snapshot-second-window") {
                // File ▸ New Window, then open a folder in it.
                if let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
                   let index = fileMenu.items.firstIndex(where: { $0.title == "New Window" }) {
                    fileMenu.performActionForItem(at: index)
                }
                try? await Task.sleep(for: .milliseconds(800))
                if let second = Workspace.current, second !== workspace {
                    await second.openFolder(URL(fileURLWithPath: folder))
                }
                try? await Task.sleep(for: .seconds(3))
                let windows = NSApp.windows.filter { $0.isVisible && $0.parent == nil && $0.contentView != nil }
                print("windows: \(windows.map(\.title)) workspaces: \(Workspace.allOpen.compactMap { $0.rootURL?.lastPathComponent })")
                if args.contains("--snapshot-close-second") {
                    let target = windows.first { $0.title == URL(fileURLWithPath: folder).lastPathComponent }
                    if let target, let delegate = target.delegate {
                        print("delegate: \(type(of: delegate)) shouldClose: \(delegate.windowShouldClose?(target) ?? true) key: \(NSApp.keyWindow?.title ?? "nil")")
                    }
                    target?.performClose(nil)
                    try? await Task.sleep(for: .seconds(1))
                    let remaining = NSApp.windows.filter { $0.isVisible && $0.parent == nil && $0.contentView != nil }
                    print("after close: \(remaining.map(\.title)) workspaces: \(Workspace.allOpen.compactMap { $0.rootURL?.lastPathComponent })")
                }
            }
            if let action = value("--snapshot-fold"), let workspace {
                let actions: [String: FoldAction] = ["fold": .fold, "all": .foldAll, "unfold": .unfold]
                if let action = actions[action] { workspace.requestFold(action) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if args.contains("--snapshot-diff"), let workspace, let document = workspace.activeDocument {
                for _ in 0..<30 where workspace.gitBase(for: document) == nil { try? await Task.sleep(for: .milliseconds(100)) }
                workspace.diffDocumentID = document.id
                try? await Task.sleep(for: .milliseconds(500))
            }
            if args.contains("--snapshot-git"), let workspace {
                workspace.sidebarMode = .git
                for _ in 0..<30 where workspace.gitChanges.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                if let first = workspace.gitChanges.first(where: { !$0.isStaged && !$0.isUntracked }) {
                    await workspace.stage([first])
                }
                workspace.commitMessage = "Refine order summary"
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let command = value("--snapshot-go"), let workspace {
                workspace.runGo(command.split(separator: " ").map(String.init))
                for _ in 0..<100 where workspace.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let input = value("--snapshot-terminal"), let workspace {
                workspace.showTerminal()
                try? await Task.sleep(for: .seconds(2))  // shell startup
                workspace.terminal?.send(input + "\n")
                try? await Task.sleep(for: .seconds(2))
            }
            if let actions = value("--snapshot-edit"), let workspace {
                let map: [String: EditAction] = ["comment": .toggleComment, "indent": .indent, "outdent": .outdent,
                                                 "dup": .duplicateLines, "up": .moveLinesUp, "down": .moveLinesDown]
                for action in actions.split(separator: ",").compactMap({ map[String($0)] }) {
                    workspace.requestEdit(action)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ProcessInfo.processInfo.environment["RUSTIDE_DEBUG_TEXT"] != nil, let text = workspace?.activeDocument?.text {
                print(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    .map { "\($0.offset + 1): \($0.element.debugDescription)" }.joined(separator: "\n"))
            }
            if args.contains("--snapshot-runconfigs"), let workspace {
                if let index = workspace.runConfigurations.firstIndex(where: { $0.name == "server" }) {
                    workspace.runConfigurations[index].arguments = "-port 8080 --name \"demo app\""
                    workspace.runConfigurations[index].environment = "LOG_LEVEL=debug"
                    workspace.selectedRunConfigurationID = workspace.runConfigurations[index].id
                }
                if args.contains("--snapshot-run") {
                    workspace.runSelectedConfiguration()
                    for _ in 0..<100 where workspace.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    print("run output:\n" + workspace.output)
                }
                workspace.isEditingRunConfigurations = true
                try? await Task.sleep(for: .milliseconds(800))
            }
            if args.contains("--snapshot-format"), let workspace {
                await workspace.formatActiveDocument()
                try? await Task.sleep(for: .milliseconds(300))
            }

            if ProcessInfo.processInfo.environment["RUSTIDE_DEBUG_LAYOUT"] != nil,
               let textView = NSApp.windows.first?.firstResponder as? NSTextView, let scroll = textView.enclosingScrollView {
                print("clip bounds=\(scroll.contentView.bounds) insets=\(scroll.contentView.contentInsets) scroll=\(scroll.frame)")
            }
            if args.contains("--snapshot-settings") {
                // Trigger the app menu's "Settings…" (⌘,) item, as a user would.
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    appMenu.performActionForItem(at: index)
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
            let settingsWindow = args.contains("--snapshot-settings")
                ? NSApp.windows.first { $0.isVisible && $0.parent == nil && $0 !== NSApp.windows.first }
                : nil
            let keyWindow = args.contains("--snapshot-second-window") ? NSApp.keyWindow : nil
            if let window = settingsWindow ?? keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.parent == nil && $0.contentView != nil }),
               let image = render(window) {
                try? image.write(to: URL(fileURLWithPath: path))
                print("snapshot written to \(path)")
            } else {
                print("snapshot failed: no window")
            }
            if let workspace, workspace.isDebugging {
                workspace.stopDebugging()  // don't leave dlv behind
                try? await Task.sleep(for: .milliseconds(800))
            }
            exit(0)  // skip the unsaved-changes prompt
        }
    }

    private static func layerRenderedViews(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        for subview in view.subviews {
            if String(describing: type(of: subview)).contains("TerminalView") { found.append(subview) }
            found += layerRenderedViews(in: subview)
        }
        return found
    }

    /// The window's frame view plus any visible child windows (completion, signature
    /// popups) composited at their on-screen offsets, as PNG data.
    private static func render(_ window: NSWindow) -> Data? {
        guard let root = window.contentView?.superview ?? window.contentView,
              let base = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: base)

        let image = NSImage(size: root.bounds.size)
        image.lockFocus()
        base.draw(in: root.bounds)
        // Layer-rendered views (the SwiftTerm terminal) don't show up in cacheDisplay: draw their layers.
        if let context = NSGraphicsContext.current?.cgContext {
            for view in layerRenderedViews(in: root) {
                guard let layer = view.layer, !view.isHiddenOrHasHiddenAncestor else { continue }
                let frame = view.convert(view.bounds, to: root)
                context.saveGState()
                // root is flipped (window frame view); CG context is not.
                context.translateBy(x: frame.minX, y: root.isFlipped ? root.bounds.height - frame.maxY : frame.minY)
                if view.isFlipped {
                    context.translateBy(x: 0, y: frame.height)
                    context.scaleBy(x: 1, y: -1)
                }
                layer.render(in: context)
                context.restoreGState()
            }
        }
        for child in (window.childWindows ?? []) + [window.attachedSheet].compactMap({ $0 }) where child.isVisible {
            guard let view = child.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            NSColor.black.withAlphaComponent(0.15).setFill()  // stand-in for the window shadow
            NSRect(origin: origin, size: view.bounds.size).insetBy(dx: -1, dy: -1).frame()
            rep.draw(in: NSRect(origin: origin, size: view.bounds.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
