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

extension LoginItemTests {
    func testFinderRegistrationSurvivesBuildChangeAndHonorsSystemRevocation() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var system = SMAppService.Status.notRegistered
        var calls: [Bool] = []
        func model(_ build: String) -> FinderRegistration {
            FinderRegistration(defaults: defaults, build: build, status: { system }, register: {
                calls.append(true)
                system = .requiresApproval
            }, unregister: {
                calls.append(false)
                system = .notRegistered
            })
        }
        let first = model("first")
        first.offerRecoveryAtLaunch { _, _ in
            XCTFail("A fresh install has no helper permission to recover.")
            return false
        }
        XCTAssertFalse(first.requested)
        first.setRequested(true)
        XCTAssertEqual(first.recovery, .approve)
        system = .enabled
        first.refresh()
        XCTAssertTrue(first.ready)
        let updated = model("second")
        XCTAssertEqual(updated.recovery, .registerBuild)
        XCTAssertFalse(updated.ready)
        XCTAssertEqual(calls, [true])
        updated.offerRecoveryAtLaunch { _, _ in false }
        XCTAssertEqual(calls, [true])
        updated.setRequested(true)
        XCTAssertEqual(updated.recovery, .approve)
        system = .enabled
        updated.refresh()
        XCTAssertTrue(updated.ready)
        system = .requiresApproval
        updated.refresh()
        XCTAssertEqual(updated.recovery, .approve)
        XCTAssertEqual(calls, [true, false, true])
        system = .notRegistered
        updated.refresh()
        XCTAssertTrue(updated.requested)
        XCTAssertEqual(updated.recovery, .registerBuild)
        updated.setRequested(false)
        XCTAssertFalse(model("third").requested)
    }
}
