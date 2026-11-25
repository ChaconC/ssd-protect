import AppKit
import DriveArbitration
import SwiftUI
import XCTest
@testable import SSDProtect

final class MenuAccessibilityTests: XCTestCase {
    @MainActor
    func testDefaultPressAndVoiceOverChordUseOrdinaryEject() throws {
        _ = NSApplication.shared
        let button = EjectButton()
        var ordinary = 0
        var forced = 0
        button.eject = { ordinary += 1 }
        button.forceEject = { forced += 1 }
        func space(_ flags: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil, characters: " ",
                                           charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49))
        }

        XCTAssertTrue(button.accessibilityPerformPress())
        button.keyDown(with: try space([.control, .option]))
        XCTAssertEqual(ordinary, 2)
        XCTAssertEqual(forced, 0)

        button.keyDown(with: try space(.option))
        button.keyDown(with: try space(.option, repeatKey: true))
        XCTAssertEqual(forced, 1)
        XCTAssertEqual(ordinary, 2)
        button.isEnabled = false
        XCTAssertFalse(button.accessibilityPerformPress())
        button.keyDown(with: try space(.option))
        XCTAssertEqual(forced, 1)
    }

    @MainActor
    func testPointerActivationRequiresAnOptionOnlyClick() throws {
        _ = NSApplication.shared
        var ordinary = 0
        var forced = 0
        let actions = DriveActions(name: "Sample", protected: .constant(false), optionDown: true,
                                   eject: { ordinary += 1 }, forceEject: { forced += 1 })
        let host = NSHostingView(rootView: HStack { actions })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findButton(in view: NSView) -> EjectButton? {
            if let button = view as? EjectButton { return button }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        let button = try XCTUnwrap(findButton(in: host))
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(ordinary, 1, "The default action stays ordinary even when the alternate help is visible.")

        var eventNumber = 0
        func click(_ modifiers: NSEvent.ModifierFlags) throws {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            eventNumber += 2
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: eventNumber + (type == .leftMouseUp ? 1 : 0), clickCount: 1, pressure: 1))
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            button.mouseDown(with: try event(.leftMouseDown))
        }
        try click(.option)
        try click([])
        try click([.control, .option])
        XCTAssertEqual(ordinary, 3)
        XCTAssertEqual(forced, 1)
    }

    func testMenuBarAnnouncesProtectedAndSuspendedAttachments() {
        var inventory = Inventory()
        inventory.available = true
        inventory.protected = [1]
        inventory.suspendedAPFS = [2, 3]
        XCTAssertEqual(inventory.menuBarStatus, "Protecting 1 drive · 2 suspended")
    }
}
