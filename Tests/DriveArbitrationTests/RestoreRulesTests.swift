import XCTest
@testable import DriveArbitration

final class RestoreRulesTests: XCTestCase {
    let original = IdentityEvidence(device: "device-a", media: "media-a")
    let other = IdentityEvidence(device: "device-b", media: "media-b")
    let suite = "RestoreRulesTests-\(UUID())"
    var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOnlyExplicitRulesSurviveRestartWithNewAttachments() {
        var rules = RestoreRules(defaults: defaults)
        XCTAssertFalse(rules.enabled)
        let disks: [UInt64: IdentityEvidence] = [1: original, 2: other]
        rules.record(1, evidence: disks)
        rules.setEnabled(true)
        XCTAssertFalse(rules.matches(1, evidence: disks))
        rules.record(1, evidence: disks)
        let restarted = RestoreRules(defaults: defaults)
        let reattached: [UInt64: IdentityEvidence] = [1: other, 99: original]
        XCTAssertTrue(restarted.matches(99, evidence: reattached))
        XCTAssertFalse(restarted.matches(1, evidence: reattached))
        XCTAssertTrue(restarted.bindings.isEmpty)
    }

    func testAmbiguousOrIncompleteIdentitiesCannotTransferAfterOneCopyLeaves() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        rules.record(1, evidence: [1: original])
        let collision: [UInt64: IdentityEvidence] = [1: original, 2: IdentityEvidence(device: nil, media: original.media)]
        XCTAssertFalse(rules.matches(1, evidence: collision))
        rules.discardCollisions(in: collision)
        rules.record(2, evidence: collision)
        XCTAssertFalse(RestoreRules(defaults: defaults).matches(9, evidence: [9: original]))
        rules.record(3, evidence: [3: IdentityEvidence(device: "device-a", media: nil)])
        XCTAssertTrue(rules.bindings.isEmpty)
    }

    func testStartupOwnersRequireCompleteAndUnambiguousBackingStores() {
        let boot = DiskRecord(id: "boot", stores: [.init(id: "bootStore")], volumes: [])
        let physical = DiskRecord(id: "whole", partitions: [.init(id: "bootStore")])
        XCTAssertEqual(DriveInventory.startupOwners(in: [boot, physical], startup: "boot"), ["whole"])
        XCTAssertEqual(DriveInventory.startupOwners(in: [physical], startup: "whole"), ["whole"])
        XCTAssertNil(DriveInventory.startupOwners(in: [boot], startup: "boot"))
        XCTAssertNil(DriveInventory.startupOwners(in: [physical], startup: nil))
        let duplicate = DiskRecord(id: "other", partitions: [.init(id: "bootStore")])
        XCTAssertNil(DriveInventory.startupOwners(in: [boot, physical, duplicate], startup: "boot"))
    }

    func testChangedHardwareOrMediaCannotRestoreWithoutOriginalPresent() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        rules.record(1, evidence: [1: original])
        XCTAssertFalse(rules.matches(1, evidence: [1: .init(device: original.device, media: other.media)]))
        XCTAssertFalse(rules.matches(1, evidence: [1: .init(device: other.device, media: original.media)]))
    }

    func testPreviouslyObservedIdentifierReuseRetiresTheSavedChoice() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        rules.record(1, evidence: [1: original])
        rules.disconnected(1)
        rules.discardCollisions(in: [2: .init(device: other.device, media: original.media)])
        XCTAssertFalse(RestoreRules(defaults: defaults).matches(3, evidence: [3: original]))
    }

    func testFailedEjectLeavesUnmountedRestoredLeafProtectedUntilDisconnection() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        rules.record(10, evidence: [10: original])
        rules.bindRestored(10, evidence: [10: original])
        var leaf = Protection()
        var apfs = APFSEnrollments()
        leaf.enrolled.insert(10)
        leaf.operation = (10, .unmount)
        // Unmount succeeded. Only the intentional eject has a permit.
        leaf.operation = (10, .eject)
        XCTAssertFalse(leaf.veto(10, .eject))
        // macOS declined eject. The physical attachment remains, but the
        // mounted filesystem UUID is no longer available to the verifier.
        leaf.operation = nil
        rules.recheckRestored([10: .unmountedLeaf], evidence: [10: .init(device: original.device, media: nil)],
                              ejecting: nil, leaf: &leaf, apfs: &apfs)
        XCTAssertTrue(leaf.veto(10, .eject))
        XCTAssertNotNil(rules.bindings[10])
        rules.recheckRestored([11: .unmountedLeaf], evidence: [11: original],
                              ejecting: nil, leaf: &leaf, apfs: &apfs)
        XCTAssertFalse(leaf.veto(10, .eject))
        XCTAssertFalse(leaf.veto(11, .eject))
        XCTAssertTrue(rules.hasChoices)
    }

    func testEjectingOneDriveDoesNotMaskAnotherRestoredDrivesMissingIdentity() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        let evidence: [UInt64: IdentityEvidence] = [1: original, 2: other]
        var leaf = Protection()
        var apfs = APFSEnrollments()
        var targets: [UInt64: RestoreTarget] = [:]
        for (id, bsd) in [(UInt64(1), "first"), (2, "second")] {
            rules.record(id, evidence: evidence)
            rules.bindRestored(id, evidence: evidence)
            let target = APFSProtectionTarget(id: id, wholeBSD: bsd, members: [bsd: id], containers: [])
            apfs.enroll(target)
            apfs.recheck(id, live: id, target: target)
            targets[id] = .apfs(target)
        }
        let partial: [UInt64: IdentityEvidence] = [1: original, 2: .init(device: nil, media: other.media)]
        rules.recheckRestored(targets, evidence: partial, ejecting: 1, leaf: &leaf, apfs: &apfs)
        XCTAssertEqual(Set(apfs.verified.keys), [1])
        XCTAssertEqual(apfs.suspended, [2])
        XCTAssertNotNil(rules.bindings[2])
    }

    func testDisableAndGlobalOptOutClearSavedChoices() {
        var rules = RestoreRules(defaults: defaults)
        rules.setEnabled(true)
        let disks: [UInt64: IdentityEvidence] = [1: original, 2: other]
        rules.record(1, evidence: disks)
        rules.record(2, evidence: disks)
        rules.forget(1)
        XCTAssertFalse(RestoreRules(defaults: defaults).matches(1, evidence: disks))
        XCTAssertTrue(rules.matches(2, evidence: disks))
        rules.setEnabled(false)
        rules.setEnabled(true)
        XCTAssertFalse(rules.matches(2, evidence: disks))
    }
}
