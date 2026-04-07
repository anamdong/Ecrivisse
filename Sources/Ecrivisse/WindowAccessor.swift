import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let accessorView = nsView as? AccessorView else { return }
        accessorView.onResolve = onResolve
        DispatchQueue.main.async {
            accessorView.onResolve?(accessorView.window)
        }
    }

    private final class AccessorView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }
}
