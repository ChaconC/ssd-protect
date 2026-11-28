import XCTest
@testable import DriveArbitration

final class FeedbackExpiryTests: XCTestCase {
    func testEachSuccessGetsItsOwnDeadlineAndPersistentFeedbackSurvives() {
        var callbacks: [() -> Void] = []
        let expiry = FeedbackExpiry { delay, callback in
            XCTAssertEqual(delay, 10)
            callbacks.append(callback)
        }
        var message = "Unmounted Example. The drive is still connected."
        func showSuccess() { expiry.schedule { message = "" } }
        showSuccess()
        showSuccess()
        callbacks[0]()
        XCTAssertFalse(message.isEmpty)
        callbacks[1]()
        XCTAssertEqual(message, "")
        message = "Finder relaunch requested."
        showSuccess()
        expiry.cancel()
        message = "Drive changed. Reopen the drive menu."
        callbacks[2]()
        XCTAssertEqual(message, "Drive changed. Reopen the drive menu.")
    }
}
