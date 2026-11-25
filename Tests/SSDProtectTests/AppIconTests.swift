import AppKit
import XCTest
@testable import SSDProtect

final class AppIconTests: XCTestCase {
    func testChoosingAppearanceUpdatesRunningAppAndSurvivesRelaunch() throws {
        let suite = "AppIconTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let light = NSImage(size: NSSize(width: 32, height: 32))
        let dark = NSImage(size: NSSize(width: 32, height: 32))
        var applied: [NSImage?] = []
        func launch() -> AppIconSettings {
            let icons = AppIconSettings(defaults: defaults, load: { $0 == .light ? light : dark },
                                        apply: { applied.append($0) })
            icons.applySavedAppearance()
            return icons
        }
        let first = launch()
        XCTAssertEqual(first.choice, .system)
        first.select(.light)
        XCTAssertTrue(applied.last! === light)
        first.select(.dark)
        XCTAssertTrue(applied.last! === dark)
        let restarted = launch()
        XCTAssertEqual(restarted.choice, .dark)
        XCTAssertTrue(applied.last! === dark)
        restarted.select(.system)
        XCTAssertNil(applied.last!)
        XCTAssertEqual(launch().choice, .system)
    }
}
