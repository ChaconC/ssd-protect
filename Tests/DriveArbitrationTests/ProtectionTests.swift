import XCTest
@testable import DriveArbitration

final class ProtectionTests: XCTestCase {
    func testLateDisappearanceCannotRetireReplacement() {
        var attachments = Attachments()
        attachments["diskX"] = 11
        attachments["diskX"] = 22
        XCTAssertNil(attachments.retire("diskX", departing: 11, live: 22))
        XCTAssertNil(attachments.retire("diskX", departing: nil, live: 22))
        XCTAssertEqual(attachments["diskX"], 22)
        XCTAssertEqual(attachments.retire("diskX", departing: 22, live: nil), 22)
        XCTAssertNil(attachments["diskX"])
    }

    func testConfirmationPermitsOnlyTheTargetAndCurrentPhase() {
        var policy = Protection()
        policy.enrolled = [11, 22]
        XCTAssertTrue(policy.veto(11, .unmount))
        XCTAssertTrue(policy.veto(11, .eject))
        XCTAssertFalse(policy.veto(33, .eject))

        policy.operation = (11, .unmount)
        XCTAssertFalse(policy.veto(11, .unmount))
        XCTAssertTrue(policy.veto(11, .eject))
        XCTAssertTrue(policy.veto(22, .unmount))

        policy.operation = (11, .eject)
        XCTAssertTrue(policy.veto(11, .unmount))
        XCTAssertFalse(policy.veto(11, .eject))
        policy.operation = nil
        XCTAssertTrue(policy.veto(11, .eject))
    }
}
