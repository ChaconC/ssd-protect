import DiskArbitration
import Foundation
import IOKit
import OSLog

public struct Drive: Identifiable, Equatable {
    public let id: UInt64
    public let name: String
    public let mount: URL
    public let transport: String
    fileprivate let bsd: String
}

public struct Inventory {
    public var drives: [Drive] = []
    public var protected: Set<UInt64> = []
    public var available: Bool?
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
        return Drive(id: id, name: name, mount: url, transport: transport, bsd: bsd)
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
    private var active: UUID?
    private var uncertain: Set<UInt64> = []
    private var message = ""
    private var started = false

    private let topologyChanged: () -> Void
    private let verifier = DispatchQueue(label: "SSDProtect.VerifyAPFS", qos: .userInitiated)
    private let testImageID: UInt64?
    private var apfsRules: [UInt64: APFSProtectionTarget] = [:]
    private var apfsAttachments = Attachments()
    private var pendingEnrollment: [UInt64: UUID] = [:]
    private var topologyRevision: UInt64 = 0
    private var rescanScheduled = false

    public convenience init(topologyChanged: @escaping () -> Void = {}, update: @escaping (Inventory) -> Void) {
        self.init(testImageID: nil, topologyChanged: topologyChanged, update: update)
    }

    init(testImageID: UInt64?, topologyChanged: @escaping () -> Void = {}, update: @escaping (Inventory) -> Void) {
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
            if enabled { self.policy.enrolled.insert(target.id) }
            else { self.policy.enrolled.remove(target.id) }
            self.publish()
        }
    }

    public func protect(_ target: APFSProtectionTarget, enabled: Bool) {
        queue.async {
            self.pendingEnrollment.removeValue(forKey: target.id)
            guard enabled else {
                self.apfsRules.removeValue(forKey: target.id)
                self.publish()
                return
            }
            let request = UUID()
            self.pendingEnrollment[target.id] = request
            self.verifyEnrollment(target, request: request)
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
                self.install(target)
                self.publish()
            }
        }
    }

    private func topologyDidChange() {
        DispatchQueue.main.async(execute: topologyChanged)
        topologyRevision &+= 1
        guard !apfsRules.isEmpty, !rescanScheduled else { return }
        rescanScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { self.recheckRules() }
    }

    private func recheckRules() {
        let revision = topologyRevision
        let existing = apfsRules
        verifier.async {
            let rows = try? DriveInventory.read(testImageID: self.testImageID)
            self.queue.async {
                guard self.topologyRevision == revision else { self.recheckRules(); return }
                self.rescanScheduled = false
                guard let rows else {
                    self.report("Could not refresh APFS topology. Existing verified attachments remain protected.")
                    return
                }
                for (id, previous) in existing where self.apfsRules[id] == previous {
                    let updated = rows.compactMap(\.apfsTarget).first { $0.id == id }
                    if let updated {
                        self.install(updated)
                    } else {
                        self.apfsRules.removeValue(forKey: id)
                        self.message = "APFS protection stopped for a disconnected or changed drive."
                    }
                }
                self.publish()
            }
        }
    }

    private func install(_ target: APFSProtectionTarget) {
        apfsRules[target.id] = target
        for (bsd, member) in target.members { apfsAttachments[bsd] = member }
    }

    private func retireAPFSRoot(_ id: UInt64) {
        guard apfsRules.removeValue(forKey: id) != nil else { return }
        message = "APFS protection stopped for a disconnected drive."
        publish()
    }

    private func refresh(_ disk: DADisk) {
        topologyDidChange()
        guard let media = Media(disk) else { return }
        for (id, rule) in apfsRules {
            if rule.wholeBSD == media.bsd && id != media.id { retireAPFSRoot(id) }
            else { apfsRules[id]?.observe(media) }
        }
        if !apfsRules.isEmpty { apfsAttachments[media.bsd] = media.id }
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
        let apfsVeto = apfsRules.values.contains { $0.covers(bsd, observed: observed) }
        let veto = apfsVeto || byBSD[bsd].map { policy.veto($0, phase) } == true
        guard apfsVeto || byBSD[bsd] != nil else { return nil }
        log.info("Approval phase=\(String(describing: phase), privacy: .public) veto=\(veto, privacy: .public)")
        guard veto else { return nil }
        queue.async { self.report("Blocked an ordinary \(phase) request.") }
        let dissent = DADissenterCreate(nil, Int32(truncatingIfNeeded: kDAReturnNotPermitted), "Protected by SSD Protect" as CFString)
        return .passRetained(dissent)
    }

    // Call only after the user confirms this exact attachment and mounted volume.
    public func ejectConfirmed(_ target: Drive) {
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
            DADiskUnmount(media.disk, UInt32(kDADiskUnmountOptionWhole), completed, reply.retainedContext())
        }
    }

    private func failed(_ step: String, _ dissent: DADissenter) {
        let status = DADissenterGetStatus(dissent)
        let reason = (DADissenterGetStatusString(dissent) as String?) ?? "Disk Arbitration status \(status)"
        finish(status == Int32(truncatingIfNeeded: kDAReturnBusy) ? "\(step) failed. The drive is busy." : "\(step) failed. \(reason)")
    }

    private func finish(_ message: String) {
        active = nil
        policy.operation = nil
        report(message)
    }

    private func report(_ text: String) {
        message = text
        publish()
    }

    private func publish() {
        let state = Inventory(drives: Array(drives.values).sorted { $0.name < $1.name },
                              protected: policy.enrolled.union(apfsRules.keys), available: session != nil, busy: active != nil, message: message)
        DispatchQueue.main.async { self.deliver(state) }
    }
}

private extension Inventory {
    init(drives: [Drive], protected: Set<UInt64>, available: Bool, busy: Bool, message: String) {
        self.drives = drives
        self.protected = protected
        self.available = available
        self.busy = busy
        self.message = message
    }
}
