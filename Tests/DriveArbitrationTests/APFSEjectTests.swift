import XCTest
@testable import DriveArbitration

final class APFSEjectTests: XCTestCase {
    func testEjectAdvancesToWholeDriveAfterConfirmedVolumeUnmounts() {
        var expected = APFSProtectionTarget(id: 10, wholeBSD: "whole", members: ["whole": 10, "volume": 23],
                                            containers: [], mountedVolumes: ["volume": URL(fileURLWithPath: "/Volumes/Test")],
                                            unencryptedMountedMembers: ["volume"], singleVolumeBSD: "volume")
        var current = expected
        XCTAssertEqual(expected.nextEjectBSD(verifiedBy: current), "volume")

        expected.mountedVolumes = [:]
        XCTAssertNil(expected.nextEjectBSD(verifiedBy: current))
        current.mountedVolumes = [:]
        current.unencryptedMountedMembers = []
        XCTAssertEqual(expected.nextEjectBSD(verifiedBy: current), "whole")
        current.singleVolumeLocked = true
        XCTAssertEqual(expected.nextEjectBSD(verifiedBy: current), "whole")
        current.members["volume"] = 24
        XCTAssertNil(expected.nextEjectBSD(verifiedBy: current))
    }

    func testOnlyTheConfirmedMemberAndPhaseCanPassItsRule() {
        let permit = APFSEjectPermit(root: 10, member: 23, phase: .unmount)
        XCTAssertTrue(permit.allows(root: 10, observed: 23, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: 24, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: 23, phase: .eject))
        XCTAssertFalse(permit.allows(root: 12, observed: 23, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: nil, phase: .unmount))
    }
}
