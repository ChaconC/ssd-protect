import ServiceManagement
import XCTest
@testable import SSDProtect

final class LoginItemTests: XCTestCase {
    func testRequestsReadBackSystemStateAndNeverRegisterOnRefresh() {
        var system: SMAppService.Status = .notRegistered
        var requests: [Bool] = []
        let model = LoginItem(status: { system }, change: { enabled in
            requests.append(enabled)
            system = enabled ? .requiresApproval : .notRegistered
        })
        model.refresh()
        XCTAssertTrue(requests.isEmpty)
        model.setRequested(true)
        XCTAssertEqual(model.status, .requiresApproval)
        system = .enabled
        model.refresh()
        XCTAssertEqual(model.status, .enabled)
        model.setRequested(false)
        XCTAssertEqual(requests, [true, false])
        XCTAssertEqual(model.status, .notRegistered)
    }

    func testRegistrationFailureKeepsActualStatusAndProvidesRecovery() {
        let model = LoginItem(status: { .notRegistered }, change: { _ in throw CocoaError(.fileReadNoPermission) })
        model.setRequested(true)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertNotNil(model.errorMessage)
    }
}
