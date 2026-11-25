import XCTest
@testable import DriveArbitration

final class FinderMountTests: XCTestCase {
    func testUnsupportedMountSemanticsAreRejectedBeforeUnmount() {
        XCTAssertFalse(FinderMount.supports(flags: UInt32(MNT_SNAPSHOT | MNT_RDONLY)))
        XCTAssertFalse(FinderMount.supports(flags: UInt32(MNT_ROOTFS)))
        XCTAssertTrue(FinderMount.supports(flags: UInt32(MNT_LOCAL | MNT_JOURNALED | MNT_NODEV | MNT_NOSUID | MNT_AUTOMOUNTED)))
    }

    func testMountOptionsPreserveRestrictionsAcrossBothStates() {
        let flags = UInt32(MNT_RDONLY | MNT_NOEXEC | MNT_NOSUID | MNT_NODEV | MNT_IGNORE_OWNERSHIP)
        XCTAssertEqual(FinderMount.options(flags: flags, hidden: true), ["rdonly", "noexec", "nosuid", "nodev", "noowners", "automounted"])
        XCTAssertEqual(FinderMount.options(flags: flags, hidden: false), ["rdonly", "noexec", "nosuid", "nodev", "noowners"])
    }
}
