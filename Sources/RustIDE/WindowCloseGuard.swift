import AppKit
import SwiftUI

/// Asks to save a window's unsaved documents before it closes, and tracks which window's
/// workspace is current. Installed as a proxy in front of SwiftUI's own window delegate:
/// only `windowShouldClose(_:)` is handled here, everything else is forwarded.
struct WindowCloseGuardView: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        let coordinator = context.coordinator
        view.onWindow = { [workspace] window in coordinator.install(on: window, workspace: workspace) }
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {}

    @MainActor
    final class Coordinator {
        private var proxy: WindowCloseGuard?
        private var observers: [NSObjectProtocol] = []
        private weak var workspace: Workspace?

        func install(on window: NSWindow, workspace: Workspace) {
            guard observers.isEmpty else { return }
            self.workspace = workspace
            // SwiftUI assigns its own window delegate after the view lands in the window:
            // wrap it on the next turn of the run loop, and re-check whenever the window activates.
            DispatchQueue.main.async { [weak self, weak window] in
                if let window { self?.wrapDelegate(of: window) }
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let workspace = self?.workspace { Workspace.current = workspace }
                    if let window { self?.wrapDelegate(of: window) }
                }
            })
            // Reliable cleanup (SwiftUI doesn't always call onDisappear when a window closes).
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let workspace = self.workspace else { return }
                    Task { await workspace.shutdown() }
                    self.observers.forEach(NotificationCenter.default.removeObserver)
                    self.observers = []
                }
            })
        }

        private func wrapDelegate(of window: NSWindow) {
            guard window.delegate !== proxy || proxy == nil else { return }
            let proxy = WindowCloseGuard(original: window.delegate) { [weak self] in
                guard let workspace = self?.workspace else { return true }
                let dirty = workspace.dirtyDocuments
                return dirty.isEmpty || workspace.resolveUnsaved(dirty)
            }
            window.delegate = proxy
            self.proxy = proxy
        }
    }
}

final class WindowObserverView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: @MainActor () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping @MainActor () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    // Forward every other delegate message to SwiftUI's delegate.
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
