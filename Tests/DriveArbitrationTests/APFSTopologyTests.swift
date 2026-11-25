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

    func testAttachedContainerRequiresExplicitVolumeList() {
        let missing = DiskRecord(id: "container", stores: [.init(id: "store")])
        let empty = DiskRecord(id: "container", stores: [.init(id: "store")], volumes: [])
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: [external, startup, missing], startupWhole: "startup"))
        XCTAssertEqual(APFSProtectionTarget.memberNames(of: external, disks: [external, startup, empty], startupWhole: "startup"),
                       ["physical", "store", "container"])
    }

    func testReusedOrRetiredBSDNameCannotReceiveAnOldVeto() {
        let rule = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4, "volume": 10], containers: [])
        XCTAssertTrue(rule.covers("volume", observed: 10))
        XCTAssertFalse(rule.covers("volume", observed: 11))
        XCTAssertFalse(rule.covers("volume", observed: nil))
        XCTAssertFalse(rule.covers("replacement", observed: 10))
    }

    func testInconclusiveRecheckSuspendsVetoUntilSameRootIsVerifiedAgain() {
        var enrollments = APFSEnrollments()
        let initial = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4, "volume": 10], containers: [])
        enrollments.enroll(initial)
        XCTAssertTrue(enrollments.verified[4]?.covers("volume", observed: 10) == true)

        enrollments.recheck(4, live: 4, target: nil)
        XCTAssertNil(enrollments.verified[4])
        XCTAssertEqual(enrollments.suspended, [4])
        enrollments.recheck(4, live: nil, target: initial)
        XCTAssertNil(enrollments.verified[4])

        let refreshed = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4, "volume": 11], containers: [])
        enrollments.recheck(4, live: 4, target: refreshed)
        XCTAssertTrue(enrollments.verified[4]?.covers("volume", observed: 11) == true)
        XCTAssertFalse(enrollments.verified[4]?.covers("volume", observed: 10) == true)
        XCTAssertTrue(enrollments.suspended.isEmpty)
    }

    func testReusedWholeDiskNameRetiresSuspendedEnrollment() {
        var enrollments = APFSEnrollments()
        let old = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4], containers: [])
        let replacement = APFSProtectionTarget(id: 5, wholeBSD: "whole", members: ["whole": 5], containers: [])
        enrollments.enroll(old)
        enrollments.recheck(4, live: nil, target: nil)
        XCTAssertEqual(enrollments.suspended, [4])
        enrollments.recheck(4, live: 5, target: replacement)
        XCTAssertTrue(enrollments.suspended.isEmpty)
        enrollments.recheck(4, live: 4, target: old)
        XCTAssertTrue(enrollments.verified.isEmpty)
    }

    func testRemovingSuspendedEnrollmentPreventsReactivationByAnInFlightScan() {
        var enrollments = APFSEnrollments()
        let target = APFSProtectionTarget(id: 4, wholeBSD: "whole", members: ["whole": 4], containers: [])
        enrollments.enroll(target)
        enrollments.recheck(4, live: 4, target: nil)
        XCTAssertEqual(enrollments.suspended, [4])
        enrollments.remove(4)
        enrollments.recheck(4, live: 4, target: target)
        XCTAssertTrue(enrollments.suspended.isEmpty)
        XCTAssertTrue(enrollments.verified.isEmpty)
    }

    func testStartupUnknownOrSharedPhysicalStoreDisqualifiesWholeDrive() {
        let normal = [external, startup, container]
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal, startupWhole: nil))
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal, startupWhole: "container"))
        let mixed = DiskRecord(id: "other", stores: [.init(id: "store"), .init(id: "otherStore")])
        XCTAssertNil(APFSProtectionTarget.memberNames(of: external, disks: normal + [mixed], startupWhole: "startup"))
    }
}
