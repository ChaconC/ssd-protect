import XCTest
@testable import DriveArbitration

final class APFSTopologyTests: XCTestCase {
    let external = DiskRecord(id: "physical", partitions: [.init(id: "store", content: "Apple_APFS")])
    let startup = DiskRecord(id: "startup")
    let container = DiskRecord(id: "container", stores: [.init(id: "store")],
                               volumes: [.init(id: "volA"), .init(id: "volB")])

    func testWholePartitionContainerAndAllSiblingsBelongToOneEnrollment() {
        let members = APFSProtectionTarget.memberNames(of: external, disks: [external, startup, container], startupWhole: "startup")
        XCTAssertEqual(members, ["physical", "store", "container", "volA", "volB"])
    }

    func testReusedOrRetiredBSDNameCannotReceiveAnOldVeto() {
        let rule = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4, "volume": 10], containers: [])
        XCTAssertTrue(rule.covers("volume", observed: 10))
        XCTAssertFalse(rule.covers("volume", observed: 11))
        XCTAssertFalse(rule.covers("volume", observed: nil))
        XCTAssertFalse(rule.covers("replacement", observed: 10))
    }

    func testStartupUnknownOrSharedPhysicalStoreDisqualifiesWholeDrive() {
        let normal = [external, startup, container]
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal, startupWhole: nil))
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal, startupWhole: "container"))
        let mixed = DiskRecord(id: "other", stores: [.init(id: "store"), .init(id: "otherStore")])
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal + [mixed], startupWhole: "startup"))
    }
}
