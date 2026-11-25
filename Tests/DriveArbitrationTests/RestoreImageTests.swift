import DiskArbitration
import XCTest
@testable import DriveArbitration

final class RestoreImageTests: XCTestCase {
    func testRestoreAcrossArbitratorRestartWithDesignatedImage() throws {
        guard let path = ProcessInfo.processInfo.environment["SSD_PROTECT_TEST_RESTORE_IMAGE"] else {
            throw XCTSkip("Set SSD_PROTECT_TEST_RESTORE_IMAGE to a disposable whole-media HFS+ image.")
        }
        let session = try XCTUnwrap(DASessionCreate(nil))
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let disk = try XCTUnwrap(DADiskCreateFromVolumePath(nil, session, url as CFURL))
        let media = try XCTUnwrap(Media(disk))
        let drive = try XCTUnwrap(media.drive)
        guard media.isDiskImage, drive.transport == "Disk Image", drive.mount.path == path else {
            return XCTFail("Expected the designated whole-media disk image.")
        }
        let suite = "RestoreImageTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = Inventory()
        // Supply fixture identity only to the independently verified image.
        // The arbitrator still has to revalidate the live attachment at commit.
        func service(failFirstScan: Bool = false) -> Arbitrator {
            var shouldFail = failFirstScan
            return Arbitrator(testImageID: nil, restorationDefaults: defaults, readForRecheck: { _ in
                if shouldFail {
                    shouldFail = false
                    throw CocoaError(.fileReadUnknown)
                }
                let rows = try DriveInventory.read()
                guard var image = rows.first(where: { $0.attachment == drive.id && $0.kind == .image }),
                      let current = DADiskCreateFromVolumePath(nil, session, url as CFURL).flatMap(Media.init),
                      current.isDiskImage, current.drive == drive else { return [] }
                image.identity = IdentityEvidence(device: "fixture-hardware", media: "fixture-media")
                image.restoreTarget = .leaf(drive)
                return [image]
            }) { state = $0 }
        }
        func wait(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
            return predicate()
        }
        var first: Arbitrator? = service()
        weak var stopped = first
        first?.start()
        guard wait({ state.drives.contains(drive) }) else { return XCTFail("Missing image.") }
        first?.protect(drive, enabled: true)
        first?.setRestoresProtection(true)
        guard wait({
            state.restoresProtection && state.protected == [drive.id] && RestoreRules(defaults: defaults).hasChoices
        }) else {
            return XCTFail("Image selection was not saved.")
        }
        first = nil
        guard wait({ stopped == nil }) else { return XCTFail("Original arbitrator still running.") }
        state = Inventory()
        let second = service(failFirstScan: true)
        second.start()
        guard wait({ state.protected == [drive.id] }) else { return XCTFail("Image did not regain protection.") }
        XCTAssertFalse(state.busy)
        second.protect(drive, enabled: false)
        XCTAssertTrue(wait { state.protected.isEmpty })
        XCTAssertFalse(RestoreRules(defaults: defaults).hasChoices)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
