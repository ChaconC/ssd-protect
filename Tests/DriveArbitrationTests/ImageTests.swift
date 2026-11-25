import DiskArbitration
import XCTest
@testable import DriveArbitration

private final class UnmountResult {
    var status: DAReturn?
}

final class ImageTests: XCTestCase {
    // Opt-in with the exact mount path of a disposable, whole-media disk image.
    func testProtectedImageRejectsUnmountThenEjectsAfterConfirmation() throws {
        try exerciseImage(variable: "SSD_PROTECT_TEST_IMAGE", force: false)
    }

    func testExplicitForceEjectUnmountsBusyProtectedLeafImage() throws {
        try exerciseImage(variable: "SSD_PROTECT_TEST_FORCE_IMAGE", force: true)
    }

    private func exerciseImage(variable: String, force: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) to exercise a disposable mounted image.")
        }
        var state = Inventory()
        let service = Arbitrator { state = $0 }
        service.start()
        defer { withExtendedLifetime(service) {} }

        func waitUntil(_ predicate: @escaping () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return predicate()
        }
        func target() -> Drive? {
            state.drives.first { $0.mount.path == path && $0.transport == "Disk Image" }
        }
        XCTAssertTrue(waitUntil { target() != nil }, "Disposable image did not appear")
        let drive = try XCTUnwrap(target())
        service.protect(drive, enabled: true)
        guard waitUntil({ state.protected.contains(drive.id) }) else {
            return XCTFail("The disposable image was not enrolled.")
        }

        let session = try XCTUnwrap(DASessionCreate(nil))
        DASessionSetDispatchQueue(session, .main)
        defer { DASessionSetDispatchQueue(session, nil) }
        let disk = try XCTUnwrap(DADiskCreateFromVolumePath(nil, session, drive.mount as CFURL))
        guard Media(disk)?.drive == drive else { return XCTFail("Disposable attachment changed.") }
        let result = UnmountResult()
        DADiskUnmount(disk, 0, { _, dissent, ctx in
            let result = Unmanaged<UnmountResult>.fromOpaque(ctx!).takeRetainedValue()
            result.status = dissent.map(DADissenterGetStatus) ?? 0
        }, Unmanaged.passRetained(result).toOpaque())
        guard waitUntil({ result.status != nil && state.message.contains("Blocked an ordinary unmount") }),
              result.status == Int32(truncatingIfNeeded: kDAReturnNotPermitted) else {
            return XCTFail("Expected an unmount veto from SSD Protect.")
        }
        XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(atPath: path))

        let holder = Process()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }
        if force {
            holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
            holder.arguments = ["120"]
            holder.currentDirectoryURL = drive.mount
            try holder.run()
            service.forceEject(drive)
        } else {
            service.ejectConfirmed(drive)
        }
        XCTAssertTrue(waitUntil { state.message == "Ejected \(drive.name)." }, state.message)
        XCTAssertTrue(waitUntil { target() == nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
