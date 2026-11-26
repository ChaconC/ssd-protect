import XCTest
@testable import SSDProtect

final class FinderDisableScanTests: XCTestCase {
    func testUnknownFlagCannotBeTreatedAsClear() throws {
        let path = URL(fileURLWithPath: "/Volumes/Test")
        XCTAssertThrowsError(try FinderDisableScan.needsRestore(flag: nil, at: path))
        XCTAssertFalse(try FinderDisableScan.needsRestore(flag: false, at: path))
        XCTAssertTrue(try FinderDisableScan.needsRestore(flag: true, at: path))
    }

    func testStalledScanExpiresAndDiscardsLateSuccess() {
        let release = DispatchSemaphore(value: 0)
        let timedOut = expectation(description: "Deadline releases the disable flow")
        let late = expectation(description: "Old scan reopened the flow")
        late.isInverted = true
        FinderDisableScan.start(timeout: .milliseconds(30), read: {
            release.wait()
            return []
        }) { result in
            switch result {
            case .failure: timedOut.fulfill()
            case .success: late.fulfill()
            }
        }
        wait(for: [timedOut], timeout: 2)
        release.signal()
        wait(for: [late], timeout: 0.1)
    }
}
