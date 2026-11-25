import XCTest
@testable import DriveArbitration

final class RemountTests: XCTestCase {
    func testLockedVolumeReleasesBusyStateWhenVerificationStalls() {
        let readStarted = expectation(description: "Reading drive inventory")
        let timedOut = expectation(description: "Mount operation released")
        let resumeRead = DispatchSemaphore(value: 0)
        defer { resumeRead.signal() }
        let arbitrator = Arbitrator(testImageID: nil, readForRecheck: { _ in
            readStarted.fulfill()
            resumeRead.wait()
            return []
        }, update: { state in
            if !state.busy && state.message.contains("timed out") {
                timedOut.fulfill()
            }
        })
        let target = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["volume": 2],
                                          containers: [], singleVolumeBSD: "volume", singleVolumeLocked: true)
        arbitrator.remount(target, named: "Test Volume", timeout: .milliseconds(50))
        wait(for: [readStarted, timedOut], timeout: 2)
    }
}
