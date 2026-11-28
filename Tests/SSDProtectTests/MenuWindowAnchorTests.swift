import AppKit
import SwiftUI
import XCTest
@testable import SSDProtect

@MainActor
final class MenuWindowAnchorTests: XCTestCase {
    func testOpenPanelGrowsDownwardAndScrollsOnlyAtScreenLimit() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 35,
                                                  width: 40, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        anchor.contentView = button
        anchor.orderFront(nil)
        defer { anchor.orderOut(nil) }

        let limit = min(600, screen.visibleFrame.height - 100)
        let rows = RowHeights()
        let window = MenuPanel()
        window.show(below: button) { _ in MenuFixture(rows: rows, limit: limit) }
        defer { window.dismiss() }

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        settle()
        let original = window.frame
        let expanded = min(420, limit - 100)
        for heightRequest in [expanded, limit * 2, 100] {
            rows.height = heightRequest
            settle()
            let height = window.frame.height
            XCTAssertEqual(window.frame.maxY, original.maxY, accuracy: 1)
            if heightRequest == expanded {
                XCTAssertEqual(window.frame.height - original.height, expanded - 100, accuracy: 1)
            } else if heightRequest > limit {
                XCTAssertEqual(height, limit, accuracy: 1)
            } else {
                XCTAssertEqual(window.frame.height, original.height, accuracy: 1)
            }
        }

        func click(in target: NSWindow) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5),
                modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            window.handleClick(event)
        }
        try click(in: window)
        XCTAssertTrue(window.isVisible)
        try click(in: anchor)
        XCTAssertTrue(window.isVisible)
        let settings = NSWindow(contentRect: anchor.frame, styleMask: .titled, backing: .buffered, defer: false)
        try click(in: settings)
        XCTAssertFalse(window.isVisible)
    }
}

private final class RowHeights: ObservableObject {
    @Published var height: CGFloat = 100
}

private struct MenuFixture: View {
    @ObservedObject var rows: RowHeights
    let limit: CGFloat

    var body: some View {
        DriveMenuLayout(availableHeight: limit) {
            Text("SSD Protect")
        } rows: {
            Color.clear.frame(height: rows.height)
        } footer: {
            Text("Quit")
        }
    }
}
