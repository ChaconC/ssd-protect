import AppKit
import SwiftUI
import XCTest
@testable import SSDProtect

@MainActor
final class MenuWindowAnchorTests: XCTestCase {
    func testChangingHostedContentShrinksTheAttachedWindow() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 200, width: 340, height: 458),
                            styleMask: .borderless, backing: .buffered, defer: false)
        let top = panel.frame.maxY
        let host = NSHostingView(rootView: MenuWindowSizing(height: 458))
        panel.contentView = host
        for height: CGFloat in [246, 458, 246] {
            host.rootView = MenuWindowSizing(height: height)
            host.layoutSubtreeIfNeeded()
            let deadline = Date().addingTimeInterval(1)
            while panel.frame.height != height && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(panel.frame.height, height)
            XCTAssertEqual(panel.frame.maxY, top)
        }
    }

    func testExpansionAndCollapseKeepMenuTopAndHorizontalPosition() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -600, y: 500, width: 340, height: 220),
                            styleMask: .borderless, backing: .buffered, defer: true)
        defer { panel.orderOut(nil) }
        let top = panel.frame.maxY
        for height in [390, 220, 390, 220] {
            MenuWindowSizing.resize(panel, contentHeight: CGFloat(height))
            XCTAssertEqual(panel.frame.maxY, top)
            XCTAssertEqual(panel.frame.minX, -600)
            XCTAssertEqual(panel.frame.height, CGFloat(height))
        }
    }
}
