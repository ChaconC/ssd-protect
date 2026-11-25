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

    private var isDiskImage: Bool {
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

    public init(update: @escaping (Inventory) -> Void) { deliver = update }

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

    private func refresh(_ disk: DADisk) {
        guard let media = Media(disk) else { return }
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
        guard let session, let name = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: name)
        guard byBSD[bsd] != nil else { return }
        let live = DADiskCreateFromBSDName(nil, session, bsd).flatMap(Media.attachmentID)
        guard let id = byBSD.retire(bsd, departing: Media.attachmentID(disk), live: live) else { return }
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
        guard let name = DADiskGetBSDName(disk),
              let id = byBSD[String(cString: name)] else { return nil }
        let veto = policy.veto(id, phase)
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
                              protected: policy.enrolled, busy: active != nil, message: message)
        DispatchQueue.main.async { self.deliver(state) }
    }
}

private extension Inventory {
    init(drives: [Drive], protected: Set<UInt64>, busy: Bool, message: String) {
        self.drives = drives
        self.protected = protected
        self.busy = busy
        self.message = message
    }
}
