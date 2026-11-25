import XCTest
@testable import DriveArbitration

final class APFSEjectTests: XCTestCase {
    func testOnlyTheConfirmedMemberAndPhaseCanPassItsRule() {
        let permit = APFSEjectPermit(root: 10, member: 23, phase: .unmount)
        XCTAssertTrue(permit.allows(root: 10, observed: 23, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: 24, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: 23, phase: .eject))
        XCTAssertFalse(permit.allows(root: 12, observed: 23, phase: .unmount))
        XCTAssertFalse(permit.allows(root: 10, observed: nil, phase: .unmount))
    }
}
