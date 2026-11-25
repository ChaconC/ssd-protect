import AppKit
import SwiftUI

/// MenuBarExtra can keep its largest window and center smaller content inside it.
struct MenuWindowSizing: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        guard view.height != height else { return }
        view.height = height
        view.scheduleResize()
    }

    final class Probe: NSView {
        var height: CGFloat = 0
        private var pending = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scheduleResize() }
        }

        func scheduleResize() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pending = false
                guard let window, height > 0 else { return }
                MenuWindowSizing.resize(window, contentHeight: height)
            }
        }
    }

    static func resize(_ window: NSWindow, contentHeight: CGFloat) {
        let old = window.frame
        var content = window.contentRect(forFrameRect: old)
        content.size.height = ceil(contentHeight)
        let height = window.frameRect(forContentRect: content).height
        guard abs(old.height - height) >= 1 else { return }
        window.setFrame(NSRect(x: old.minX, y: old.maxY - height, width: old.width, height: height),
                        display: false, animate: false)
    }
}
