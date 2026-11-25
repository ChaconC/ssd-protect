import DiskArbitration
import XCTest
@testable import DriveArbitration

final class FinderMountTests: XCTestCase {
    func testMountVerificationCanPinDirectoryWithoutReadPermission() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o100])
        defer {
            _ = chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let fd = try FinderMount.openForVerification(dir)
        defer { close(fd) }
        var info = statfs()
        XCTAssertEqual(fstatfs(fd, &info), 0)
    }

    func testFinderRemountRequiresPositiveUnencryptedEvidenceForSelectedVolume() {
        let path = URL(fileURLWithPath: "/Volumes/Test")
        var target = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["selected": 2],
                                          containers: [], mountedVolumes: ["selected": path])
        XCTAssertNil(target.finderVolume)
        target.unencryptedMountedMembers = ["other"]
        XCTAssertNil(target.finderVolume)
        target.unencryptedMountedMembers = ["selected"]
        XCTAssertEqual(target.finderVolume, path)
    }

    func testEncryptedUpdateRequiresOneMountedVolumeWithPositiveIdentity() {
        let path = URL(fileURLWithPath: "/Volumes/Test")
        var target = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["volume": 2],
                                          containers: [], mountedVolumes: ["volume": path])
        XCTAssertNil(target.encryptedFinderVolume)
        target.encryptedVolumeUUIDs["volume"] = UUID()
        XCTAssertEqual(target.encryptedFinderVolume, path)
        target.mountedVolumes["sibling"] = URL(fileURLWithPath: "/Volumes/Other")
        XCTAssertNil(target.encryptedFinderVolume)
    }

    func testStalledFinderPreflightReleasesControlsAndIgnoresLateResult() {
        let started = expectation(description: "Inventory scan started")
        let expired = expectation(description: "Controls released")
        let lateUpdate = expectation(description: "Late result changed the operation")
        lateUpdate.isInverted = true
        let resume = DispatchSemaphore(value: 0)
        let arbitrator = Arbitrator(testImageID: nil, readForRecheck: { _ in
            started.fulfill()
            resume.wait()
            return []
        }, update: { state in
            if !state.busy {
                if state.message.contains("timed out") { expired.fulfill() }
                else { lateUpdate.fulfill() }
            }
        })
        let target = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["volume": 2], containers: [],
                                          mountedVolumes: ["volume": URL(fileURLWithPath: "/Volumes/Test")],
                                          unencryptedMountedMembers: ["volume"])
        arbitrator.beginFinderChange(target, enabled: true, retrying: false, timeout: .milliseconds(50))
        wait(for: [started, expired], timeout: 2)
        resume.signal()
        wait(for: [lateUpdate], timeout: 0.1)
    }

    func testBusyStagingUnmountKeepsPathAndOriginalFlagsForNormalRetry() throws {
        let visible = URL(fileURLWithPath: "/Volumes/Test")
        let temporary = URL(fileURLWithPath: "/private/tmp/.test")
        let original = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["volume": 2],
                                           containers: [], mountedVolumes: ["volume": visible],
                                           unencryptedMountedMembers: ["volume"])
        let staged = FinderStagingMount(original: original, bsd: "volume", path: temporary,
                                       originalFlags: UInt32(MNT_NOSUID | MNT_AUTOMOUNTED))
        var mounted = original
        mounted.mountedVolumes["volume"] = temporary
        var recovery: FinderStagingMount?
        var flagsForVisibleMount: UInt32?
        func simulate(_ dissent: DADissenter?) {
            staged.leave(unmount: { options, reply in
                XCTAssertEqual(options, 0)
                reply(dissent)
            }, stillMounted: { _, entry in
                recovery = entry
            }, unmounted: {
                recovery = nil
                flagsForVisibleMount = staged.originalFlags
            })
        }
        simulate(try XCTUnwrap(DADissenterCreate(nil, Int32(truncatingIfNeeded: kDAReturnBusy), nil)))
        XCTAssertNil(flagsForVisibleMount)
        XCTAssertEqual(recovery?.path, temporary)
        XCTAssertTrue(recovery?.matches(mounted) == true)
        mounted.members["volume"] = 3
        XCTAssertFalse(recovery?.matches(mounted) == true)
        simulate(nil)
        XCTAssertNil(recovery)
        XCTAssertEqual(FinderMount.options(flags: try XCTUnwrap(flagsForVisibleMount), hidden: false), ["nosuid"])
    }

    func testTimeoutAfterStagingAllowsRetryOnlyBeforeUnmountStarts() {
        let original = APFSProtectionTarget(id: 1, wholeBSD: "whole", members: ["volume": 2],
                                            containers: [], mountedVolumes: ["volume": URL(fileURLWithPath: "/Volumes/Test")])
        let path = URL(fileURLWithPath: "/private/tmp/staged")
        let stage = FinderStagingMount(original: original, bsd: "volume", path: path, originalFlags: 0)
        var current = original
        current.mountedVolumes["volume"] = path
        XCTAssertEqual(stage.retryPathAfterTimeout(pendingUnmount: nil), path)
        XCTAssertTrue(stage.matches(current))
        current.members["volume"] = 3
        XCTAssertFalse(stage.matches(current))
        let inFlight = APFSEjectPermit(root: 1, member: 2, phase: .unmount)
        XCTAssertNil(stage.retryPathAfterTimeout(pendingUnmount: inFlight))
    }

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
