import DiskArbitration
import Foundation
import IOKit
import OSLog

public struct Drive: Identifiable, Equatable {
    public let id: UInt64
    public let name: String
    public let mount: URL
    public let icon: DriveIcon
    public let transport: String
    fileprivate let bsd: String
}

public struct Inventory {
    public var drives: [Drive] = []
    public var protected: Set<UInt64> = []
    public var suspendedAPFS: Set<UInt64> = []
    public var available: Bool?
    public var restoresProtection = false
    public var sessionOnly: Set<UInt64> = []
    public var busy = false
    public var message = ""
    public init() {}
}

struct Media {
    let disk: DADisk
    let id: UInt64
    let bsd: String
    let description: NSDictionary

    init?(_ disk: DADisk) {
        guard let id = Self.attachmentID(disk),
              let name = DADiskGetBSDName(disk),
              let details = DADiskCopyDescription(disk) else { return nil }
        self.disk = disk
        self.id = id
        self.bsd = String(cString: name)
        self.description = details as NSDictionary
    }

    static func attachmentID(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    var transport: String? {
        guard description[kDADiskDescriptionMediaWholeKey] as? Bool == true,
              description[kDADiskDescriptionMediaLeafKey] as? Bool == true,
              description[kDADiskDescriptionVolumeNetworkKey] as? Bool != true,
              let value = description[kDADiskDescriptionDeviceProtocolKey] as? String else { return nil }
        if ["Virtual Interface", "Disk Image"].contains(value) {
            return isDiskImage ? "Disk Image" : nil
        }
        guard description[kDADiskDescriptionDeviceInternalKey] as? Bool == false,
              ["USB", "Thunderbolt"].contains(value) else { return nil }
        return value
    }

    var isDiskImage: Bool {
        var entry = DADiskCopyIOMedia(disk)
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOHDIXController") != 0 {
                IOObjectRelease(entry)
                return true
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return false }
            entry = parent
        }
        return false
    }

    var drive: Drive? {
        guard let transport,
              let fs = description[kDADiskDescriptionVolumeKindKey] as? String,
              ["hfs", "msdos", "exfat"].contains(fs.lowercased()),
              let url = description[kDADiskDescriptionVolumePathKey] as? URL,
              url.deletingLastPathComponent().path == "/Volumes",
              let name = description[kDADiskDescriptionVolumeNameKey] as? String else { return nil }
        let icon = DriveIcon(kind: transport == "Disk Image" ? .image : .external, bus: transport,
                             model: description[kDADiskDescriptionDeviceModelKey] as? String)
        return Drive(id: id, name: name, mount: url, icon: icon, transport: transport, bsd: bsd)
    }
}

private func service(_ context: UnsafeMutableRawPointer?) -> Arbitrator {
    Unmanaged<Arbitrator>.fromOpaque(context!).takeUnretainedValue()
}

private final class Reply {
    let handler: (DADissenter?) -> Void
    init(_ handler: @escaping (DADissenter?) -> Void) { self.handler = handler }
    func retainedContext() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
}

private let completed: DADiskUnmountCallback = { _, dissent, context in
    Unmanaged<Reply>.fromOpaque(context!).takeRetainedValue().handler(dissent)
}

// The app owns one instance for its lifetime. All DA state and callbacks share this queue.
public final class Arbitrator {
    private let queue = DispatchQueue(label: "SSDProtect.DiskArbitration")
    private let session = DASessionCreate(nil)
    private let log = Logger(subsystem: "com.github.ChaconC.SSDProtect", category: "arbitration")
    private let deliver: (Inventory) -> Void
    private var drives: [UInt64: Drive] = [:]
    private var byBSD = Attachments()
    private var policy = Protection()
    private var apfsPermit: APFSEjectPermit?
    private var active: UUID?
    private var uncertain: Set<UInt64> = []
    private var message = ""
    private var started = false

    private let topologyChanged: () -> Void
    private let verifier = DispatchQueue(label: "SSDProtect.VerifyAPFS", qos: .userInitiated)
    private let readForRecheck: (Bool) throws -> [InventoryRow]
    private let testImageID: UInt64?
    private var enrollments = APFSEnrollments()
    private var apfsRules: [UInt64: APFSProtectionTarget] { enrollments.verified }
    private var apfsAttachments = Attachments()
    private var pendingEnrollment: [UInt64: UUID] = [:]
    private var topologyRevision: UInt64 = 0
    private var rescanScheduled = false
    private var restoration: RestoreRules
    private var pendingSaves: Set<UInt64> = []
    private var pendingRemovals: Set<UInt64> = []
    private var restored: Set<UInt64> = []

    public convenience init(restorationDefaults: UserDefaults? = nil, topologyChanged: @escaping () -> Void = {}, update: @escaping (Inventory) -> Void) {
        self.init(testImageID: nil, restorationDefaults: restorationDefaults, topologyChanged: topologyChanged, update: update)
    }

    init(testImageID: UInt64?, restorationDefaults: UserDefaults? = nil,
         readForRecheck: ((Bool) throws -> [InventoryRow])? = nil, topologyChanged: @escaping () -> Void = {}, update: @escaping (Inventory) -> Void) {
        self.readForRecheck = readForRecheck ?? { try DriveInventory.read(testImageID: testImageID, includeRestoreIdentity: $0) }
        restoration = RestoreRules(defaults: restorationDefaults)
        self.testImageID = testImageID
        self.topologyChanged = topologyChanged
        deliver = update
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            guard let session = self.session else {
                self.report("Disk Arbitration unavailable.")
                return
            }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, { disk, ctx in service(ctx).refresh(disk) }, ctx)
            DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, ctx in service(ctx).refresh(disk) }, ctx)
            DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in service(ctx).removed(disk) }, ctx)
            DARegisterDiskUnmountApprovalCallback(session, nil, { disk, ctx in service(ctx).approval(disk, .unmount) }, ctx)
            DARegisterDiskEjectApprovalCallback(session, nil, { disk, ctx in service(ctx).approval(disk, .eject) }, ctx)
            DASessionSetDispatchQueue(session, self.queue)
            self.scheduleRecheck(after: 0.15)
            self.publish()
        }
    }

    deinit {
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    private func fresh(_ target: Drive) -> Media? {
        guard let session, let disk = DADiskCreateFromBSDName(nil, session, target.bsd),
              let media = Media(disk), media.id == target.id else { return nil }
        return media
    }

    public func protect(_ target: Drive, enabled: Bool) {
        queue.async {
            guard self.active == nil, self.fresh(target)?.drive == target else {
                self.report("Drive changed. Reopen the drive menu.")
                return
            }
            if enabled {
                self.policy.enrolled.insert(target.id)
                self.saveSelection(target.id)
            } else {
                self.policy.enrolled.remove(target.id)
                self.removeSelection(target.id)
            }
            self.publish()
        }
    }

    public func protect(_ target: APFSProtectionTarget, enabled: Bool) {
        guard enabled else { disableAPFSProtection(for: target.id); return }
        queue.async {
            let request = UUID()
            self.pendingEnrollment[target.id] = request
            self.verifyEnrollment(target, request: request)
        }
    }

    public func disableAPFSProtection(for attachment: UInt64) {
        queue.async {
            self.pendingEnrollment.removeValue(forKey: attachment)
            self.enrollments.remove(attachment)
            self.removeSelection(attachment)
            self.publish()
        }
    }

    private func verifyEnrollment(_ target: APFSProtectionTarget, request: UUID) {
        let revision = topologyRevision
        verifier.async {
            let rows = try? DriveInventory.read(testImageID: self.testImageID)
            let verified = rows?.contains { $0.apfsTarget == target } == true
            self.queue.async {
                guard self.pendingEnrollment[target.id] == request else { return }
                guard self.topologyRevision == revision else {
                    self.verifyEnrollment(target, request: request)
                    return
                }
                self.pendingEnrollment.removeValue(forKey: target.id)
                guard verified, let session = self.session,
                      let root = DADiskCreateFromBSDName(nil, session, target.wholeBSD),
                      Media.attachmentID(root) == target.id else {
                    self.report("APFS topology changed. Recheck the drive before enabling protection.")
                    return
                }
                self.enrollments.enroll(target)
                self.saveSelection(target.id)
                self.rememberMembers(of: target)
                self.publish()
            }
        }
    }

    public func setRestoresProtection(_ enabled: Bool) {
        queue.async {
            guard self.restoration.enabled != enabled else { return }
            self.topologyRevision &+= 1
            self.restoration.setEnabled(enabled)
            self.restored.removeAll()
            self.pendingRemovals.removeAll()
            self.pendingSaves = enabled ? self.policy.enrolled.union(self.enrollments.roots.keys) : []
            self.scheduleRecheck(after: 0)
            self.publish()
        }
    }

    private func saveSelection(_ id: UInt64) {
        guard restoration.enabled else { return }
        topologyRevision &+= 1
        pendingRemovals.remove(id)
        pendingSaves.insert(id)
        restored.remove(id)
        scheduleRecheck(after: 0)
    }

    private func removeSelection(_ id: UInt64) {
        topologyRevision &+= 1
        pendingSaves.remove(id)
        restored.remove(id)
        if restoration.enabled, restoration.bindings[id] == nil, restoration.hasChoices {
            pendingRemovals.insert(id)
        }
        restoration.forget(id)
        scheduleRecheck(after: 0)
    }

    private func clearAttachment(_ id: UInt64) {
        pendingSaves.remove(id)
        pendingRemovals.remove(id)
        restored.remove(id)
        restoration.disconnected(id)
    }

    private var needsRecheck: Bool {
        !enrollments.roots.isEmpty || restoration.hasChoices || !pendingSaves.isEmpty || !pendingRemovals.isEmpty
    }

    private func reconcileRestoration(_ rows: [InventoryRow]) {
        guard restoration.enabled, let session else { return }
        var evidence: [UInt64: IdentityEvidence] = [:]
        for row in rows {
            if let id = row.attachment, let identity = row.identity { evidence[id] = identity }
        }
        restoration.discardCollisions(in: evidence)
        let eligible = Set(rows.compactMap { $0.restoreTarget == nil ? nil : $0.attachment })
        for id in restored {
            if restoration.bindings[id] == nil {
                // The saved identity collided. Revoke any automatically armed veto.
                enrollments.remove(id)
                policy.enrolled.remove(id)
                restored.remove(id)
            } else if active == nil && (!eligible.contains(id) || !restoration.matches(id, evidence: evidence)) {
                if enrollments.roots[id] != nil {
                    // Keep the suspended row switchable while the same attachment is present.
                    enrollments.verified.removeValue(forKey: id)
                } else {
                    policy.enrolled.remove(id)
                    restoration.disconnected(id)
                    restored.remove(id)
                }
            }
        }

        for row in rows {
            guard let id = row.attachment,
                  let root = DADiskCreateFromBSDName(nil, session, row.id),
                  Media.attachmentID(root) == id else { continue }
            if pendingRemovals.contains(id) {
                guard evidence[id]?.isUnique(in: evidence) == true else { continue }
                pendingRemovals.remove(id)
                if restoration.matches(id, evidence: evidence) {
                    restoration.record(id, evidence: evidence)
                    restoration.forget(id)
                }
                continue
            }
            guard let target = row.restoreTarget else { continue }
            if pendingSaves.contains(id) {
                restoration.record(id, evidence: evidence)
                continue
            }
            guard active == nil, !uncertain.contains(id), pendingEnrollment[id] == nil,
                  enrollments.roots[id] == nil, !policy.enrolled.contains(id),
                  restoration.matches(id, evidence: evidence) else { continue }
            switch target {
            case .leaf(let drive):
                guard drives[id] == drive, byBSD[row.id] == id, fresh(drive)?.drive == drive else { continue }
                policy.enrolled.insert(id)
            case .apfs(let apfs):
                enrollments.enroll(apfs)
                rememberMembers(of: apfs)
            }
            restored.insert(id)
            restoration.record(id, evidence: evidence)
        }
        // An explicit choice with insufficient or duplicate identity is session-only.
        pendingSaves.removeAll()
    }

    private func topologyDidChange() {
        DispatchQueue.main.async(execute: topologyChanged)
        topologyRevision &+= 1
        scheduleRecheck(after: 0.15)
    }

    private func scheduleRecheck(after delay: TimeInterval) {
        guard needsRecheck, !rescanScheduled else { return }
        rescanScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { self.recheckRules() }
    }

    private func recheckRules() {
        let revision = topologyRevision
        let roots = enrollments.roots
        guard needsRecheck else { rescanScheduled = false; return }
        let includeIdentity = restoration.enabled
        verifier.async {
            let rows = try? self.readForRecheck(includeIdentity)
            self.queue.async {
                guard self.topologyRevision == revision else { self.recheckRules(); return }
                self.rescanScheduled = false
                let previouslySuspended = self.enrollments.suspended
                for (id, bsd) in roots where self.enrollments.roots[id] == bsd {
                    let live = self.session.flatMap { DADiskCreateFromBSDName(nil, $0, bsd) }.flatMap(Media.attachmentID)
                    let target = rows?.first { $0.id == bsd }?.apfsTarget
                    self.enrollments.recheck(id, live: live, target: target)
                    if self.enrollments.roots[id] == nil { self.clearAttachment(id) }
                    if let verified = self.apfsRules[id] { self.rememberMembers(of: verified) }
                }
                if let rows { self.reconcileRestoration(rows) }
                let suspended = self.enrollments.suspended
                if previouslySuspended != suspended {
                    // The menu's last inventory may still lack the recovered target.
                    DispatchQueue.main.async(execute: self.topologyChanged)
                }
                if !suspended.isEmpty || rows == nil { self.scheduleRecheck(after: 2) }
                self.publish()
            }
        }
    }

    private func rememberMembers(of target: APFSProtectionTarget) {
        for (bsd, member) in target.members { apfsAttachments[bsd] = member }
    }

    private func retireAPFSRoot(_ id: UInt64) {
        guard enrollments.roots[id] != nil else { return }
        enrollments.remove(id)
        clearAttachment(id)
        message = "APFS protection stopped for a disconnected drive."
        publish()
    }

    private func refresh(_ disk: DADisk) {
        topologyDidChange()
        guard let media = Media(disk) else { return }
        for (id, bsd) in enrollments.roots {
            if bsd == media.bsd && id != media.id { retireAPFSRoot(id) }
            else { enrollments.verified[id]?.observe(media) }
        }
        if !enrollments.roots.isEmpty { apfsAttachments[media.bsd] = media.id }
        if let old = byBSD[media.bsd], old != media.id { forget(old) }
        if let drive = media.drive {
            byBSD[media.bsd] = media.id
            drives[media.id] = drive
        } else if byBSD[media.bsd] == media.id {
            drives.removeValue(forKey: media.id)
            // A normal unmount keeps the enrollment until physical disappearance.
            if media.transport == nil { forget(media.id) }
        } else { return }
        publish()
    }

    private func removed(_ disk: DADisk) {
        topologyDidChange()
        guard let session, let name = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: name)
        guard byBSD[bsd] != nil || apfsAttachments[bsd] != nil else { return }
        let live = DADiskCreateFromBSDName(nil, session, bsd).flatMap(Media.attachmentID)
        let departing = Media.attachmentID(disk)
        if let retired = apfsAttachments.retire(bsd, departing: departing, live: live) { retireAPFSRoot(retired) }
        guard let id = byBSD.retire(bsd, departing: departing, live: live) else { return }
        forget(id)
        publish()
    }

    private func forget(_ id: UInt64) {
        clearAttachment(id)
        drives.removeValue(forKey: id)
        policy.enrolled.remove(id)
        uncertain.remove(id)
        if policy.operation?.drive == id {
            if policy.operation?.phase == .unmount {
                active = nil
                message = "Drive disconnected before eject."
            }
            policy.operation = nil
        }
    }

    private func approval(_ disk: DADisk, _ phase: Phase) -> Unmanaged<DADissenter>? {
        guard let name = DADiskGetBSDName(disk) else { return nil }
        let bsd = String(cString: name)
        let observed = apfsAttachments[bsd]
        let apfsVeto = apfsRules.values.contains { rule in
            rule.covers(bsd, observed: observed)
                && apfsPermit?.allows(root: rule.id, observed: observed, phase: phase) != true
        }
        let veto = apfsVeto || byBSD[bsd].map { policy.veto($0, phase) } == true
        guard apfsVeto || byBSD[bsd] != nil else { return nil }
        log.info("Approval phase=\(String(describing: phase), privacy: .public) veto=\(veto, privacy: .public)")
        guard veto else { return nil }
        queue.async { self.report("Blocked an ordinary \(phase) request.") }
        let dissent = DADissenterCreate(nil, Int32(truncatingIfNeeded: kDAReturnNotPermitted), "Protected by SSD Protect" as CFString)
        return .passRetained(dissent)
    }

    /// Call after confirming every path in the supplied mount snapshot.
    public func ejectConfirmed(_ target: APFSProtectionTarget) {
        eject(target, unmountOptions: 0)
    }

    /// Explicit Option-activation for this attachment and mount snapshot.
    public func forceEject(_ target: APFSProtectionTarget) {
        eject(target, unmountOptions: UInt32(kDADiskUnmountOptionForce))
    }

    private func eject(_ target: APFSProtectionTarget, unmountOptions: DADiskUnmountOptions) {
        queue.async {
            guard self.active == nil, !self.uncertain.contains(target.id) else {
                self.report("Eject unavailable. Check the current drive and operation.")
                return
            }
            let token = UUID()
            self.active = token
            self.report("Verifying APFS drive before eject…")
            self.queue.asyncAfter(deadline: .now() + 60) {
                guard self.active == token else { return }
                self.uncertain.insert(target.id)
                self.finish("Eject timed out. Check mount state and reconnect before retrying.")
            }
            self.advanceAPFSEject(expected: target, unmountOptions: unmountOptions, token: token)
        }
    }

    private func advanceAPFSEject(expected: APFSProtectionTarget, unmountOptions: DADiskUnmountOptions, token: UUID) {
        let revision = topologyRevision
        verifier.async { [self] in
            let rows = try? DriveInventory.read(testImageID: self.testImageID)
            let row = rows?.first { $0.attachment == expected.id }
            self.queue.async { [self] in
                guard self.active == token else { return }
                guard self.topologyRevision == revision else {
                    self.advanceAPFSEject(expected: expected, unmountOptions: unmountOptions, token: token)
                    return
                }
                guard row?.apfsTarget == expected else {
                    self.finish("Drive or mount state changed. Eject stopped.")
                    return
                }
                let nextVolume = expected.mountedVolumes.keys.sorted().first
                let bsd = nextVolume ?? expected.wholeBSD
                guard let member = expected.members[bsd], let session = self.session,
                      let disk = DADiskCreateFromBSDName(nil, session, bsd), let media = Media(disk),
                      media.id == member,
                      media.description[kDADiskDescriptionVolumePathKey] as? URL == expected.mountedVolumes[bsd] else {
                    self.finish("Attachment changed. Eject stopped.")
                    return
                }
                let phase: Phase = nextVolume == nil ? .eject : .unmount
                self.apfsPermit = APFSEjectPermit(root: expected.id, member: member, phase: phase)
                let reply = Reply { [weak self] dissent in
                    guard let self, self.active == token else { return }
                    self.apfsPermit = nil
                    if let dissent {
                        self.reconcileAPFSFailure(expected, phase: phase, dissent: dissent, token: token)
                    } else if let nextVolume {
                        var remaining = expected
                        remaining.mountedVolumes.removeValue(forKey: nextVolume)
                        self.advanceAPFSEject(expected: remaining, unmountOptions: unmountOptions, token: token)
                    } else {
                        self.finish("Ejected \(row?.name ?? "APFS drive").")
                    }
                }
                if let mount = expected.mountedVolumes[bsd] {
                    self.report("Unmounting \(mount.lastPathComponent)…")
                    DADiskUnmount(disk, unmountOptions, completed, reply.retainedContext())
                } else {
                    self.report("Ejecting APFS drive…")
                    DADiskEject(disk, 0, completed, reply.retainedContext())
                }
            }
        }
    }

    private func reconcileAPFSFailure(_ target: APFSProtectionTarget, phase: Phase, dissent: DADissenter, token: UUID) {
        let step = phase == .eject ? "Eject" : "Unmount"
        let failure = failureDescription(step, dissent)
        verifier.async {
            let rows = try? DriveInventory.read(testImageID: self.testImageID)
            let current = rows?.first { $0.attachment == target.id }?.apfsTarget
            self.queue.async {
                guard self.active == token else { return }
                let status: String
                if let current {
                    let paths = current.mountedVolumes.values.map(\.path).sorted()
                    status = paths.isEmpty ? "No volumes remain mounted." : "Still mounted: " + paths.joined(separator: ", ")
                } else {
                    status = "Mount state could not be verified."
                }
                self.finish(failure + " " + status)
            }
        }
    }

    // Call only after the user confirms this exact attachment and mounted volume.
    public func ejectConfirmed(_ target: Drive) {
        eject(target, unmountOptions: 0)
    }

    /// Explicit Option-activation for this attachment and mount snapshot.
    public func forceEject(_ target: Drive) {
        eject(target, unmountOptions: UInt32(kDADiskUnmountOptionForce))
    }

    private func eject(_ target: Drive, unmountOptions: DADiskUnmountOptions) {
        queue.async { [self] in
            guard self.active == nil, !self.uncertain.contains(target.id),
                  let media = self.fresh(target), media.drive == target else {
                self.report("Eject unavailable. Verify the current attachment and mount state.")
                return
            }
            let token = UUID()
            self.active = token
            self.policy.operation = (target.id, .unmount)
            self.report("Unmounting \(target.name)…")
            self.queue.asyncAfter(deadline: .now() + 30) {
                guard self.active == token else { return }
                self.uncertain.insert(target.id)
                self.finish("Operation timed out. Check mount state and reconnect before retrying.")
            }
            let reply = Reply { [weak self] dissent in
                guard let self, self.active == token else { return }
                if let dissent { self.failed("Unmount", dissent); return }
                guard self.policy.operation?.drive == target.id,
                      let unmounted = self.fresh(target), unmounted.transport == target.transport,
                      unmounted.description[kDADiskDescriptionVolumePathKey] == nil else {
                    self.finish("Mount state changed. Eject stopped.")
                    return
                }
                self.policy.operation = (target.id, .eject)
                self.report("Ejecting \(target.name)…")
                let reply = Reply { [weak self] dissent in
                    guard let self, self.active == token else { return }
                    if let dissent { self.failed("Eject", dissent) }
                    else { self.finish("Ejected \(target.name).") }
                }
                DADiskEject(unmounted.disk, 0, completed, reply.retainedContext())
            }
            DADiskUnmount(media.disk, unmountOptions, completed, reply.retainedContext())
        }
    }

    private func failed(_ step: String, _ dissent: DADissenter) {
        finish(failureDescription(step, dissent))
    }

    private func failureDescription(_ step: String, _ dissent: DADissenter) -> String {
        let status = DADissenterGetStatus(dissent)
        let reason = (DADissenterGetStatusString(dissent) as String?) ?? "Disk Arbitration status \(status)"
        // DADissenter.h also permits BSD errors encoded by mach/error.h's unix_err().
        let unixBusy = (3 << 14) | EBUSY
        if status == Int32(truncatingIfNeeded: kDAReturnBusy) || status == unixBusy {
            return "\(step) failed. The drive is busy."
        }
        return "\(step) failed. \(reason)"
    }

    private func finish(_ message: String) {
        apfsPermit = nil
        active = nil
        policy.operation = nil
        scheduleRecheck(after: 0)
        report(message)
    }

    private func report(_ text: String) {
        message = text
        publish()
    }

    private func publish() {
        var snapshot = Inventory(drives: Array(drives.values).sorted { $0.name < $1.name },
                              protected: policy.enrolled.union(apfsRules.keys), suspendedAPFS: enrollments.suspended,
                              available: session != nil, busy: active != nil, message: message)
        snapshot.restoresProtection = restoration.enabled
        snapshot.sessionOnly = snapshot.protected.union(enrollments.suspended)
            .subtracting(restoration.bindings.keys).subtracting(pendingSaves)
        let state = snapshot
        DispatchQueue.main.async { self.deliver(state) }
    }
}

private extension Inventory {
    init(drives: [Drive], protected: Set<UInt64>, suspendedAPFS: Set<UInt64>, available: Bool, busy: Bool, message: String) {
        self.drives = drives
        self.protected = protected
        self.suspendedAPFS = suspendedAPFS
        self.available = available
        self.busy = busy
        self.message = message
    }
}
