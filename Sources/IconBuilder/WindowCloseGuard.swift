import AppKit
import SwiftUI

/// Installs a narrowly scoped window-delegate proxy so the red close button
/// follows the same Save / Don’t Save / Cancel policy as Open and Quit.
struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.model = model
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class WindowReaderView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var model: AppModel
        private weak var window: NSWindow?
        // NSObject's forwarding hooks are nonisolated even though AppKit calls
        // window delegates on the main thread. Keep this forwarding-only
        // reference explicitly outside actor checking.
        nonisolated(unsafe) private weak var previousDelegate: (any NSWindowDelegate)?

        init(model: AppModel) {
            self.model = model
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow, newWindow !== window else { return }
            detach()
            window = newWindow
            previousDelegate = newWindow.delegate
            newWindow.delegate = self
        }

        func detach() {
            if let window, window.delegate === self {
                window.delegate = previousDelegate
            }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.confirmDiscardingChanges(action: "closing the window",
                                                  markDiscarded: true) else {
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
