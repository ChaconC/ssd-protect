import AppKit
import SwiftUI

@MainActor
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    private weak var anchor: NSView?
    private var sizeObservation: NSKeyValueObservation?
    private var monitors: [Any] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    func show<Content: View>(below button: NSView, content: (CGFloat) -> Content) {
        guard let window = button.window, let screen = window.screen else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(anchorMoved),
                                               name: NSWindow.didMoveNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive(_:)),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        anchor = button
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let top = min(bounds.maxY, window.convertToScreen(button.convert(button.bounds, to: nil)).minY - 4)
        let view = content(max(1, top - bounds.minY))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        let host: NSHostingController<AnyView>
        if let existing = contentViewController as? NSHostingController<AnyView> {
            host = existing
            host.rootView = AnyView(view)
        } else {
            host = NSHostingController(rootView: AnyView(view))
            host.sizingOptions = [.preferredContentSize]
            contentViewController = host
        }
        resize(to: host.view.fittingSize)
        sizeObservation = host.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] host, _ in
            MainActor.assumeIsolated { self?.resize(to: host.preferredContentSize) }
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        monitorClicks()
    }

    @objc private func anchorMoved() {
        resize(to: frame.size)
    }

    @objc private func appResignedActive(_ notification: Notification) {
        dismiss()
    }

    private func resize(to size: NSSize) {
        guard size.width > 0, size.height > 0, let button = anchor,
              let window = button.window, let screen = window.screen else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let top = min(bounds.maxY, rect.minY - 4)
        let width = min(size.width, bounds.width)
        let height = min(size.height, max(1, top - bounds.minY))
        let x = min(max(bounds.minX, round(rect.midX - width / 2)), bounds.maxX - width)
        setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    private func monitorClicks() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in self?.dismiss() },
            NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                guard let self else { return event }
                self.handleClick(event)
                return event
            }
        ].compactMap { $0 }
    }

    func handleClick(_ event: NSEvent) {
        if event.window === self { return }
        if let anchor, let window = anchor.window, event.window === window,
           anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard attachedSheet == nil, NSApp.modalWindow == nil else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: anchor?.window)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp)
        sizeObservation = nil
        orderOut(nil)
    }
}
