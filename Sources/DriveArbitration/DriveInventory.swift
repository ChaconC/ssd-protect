import DiskArbitration
import Foundation

// diskutil list -plist includes physical partitions, synthesized containers and their stores.
struct DiskRecord: Decodable {
    let id: String
    var name: String? = nil
    var mount: String? = nil
    var size: Int64? = nil
    var partitions: [DiskRecord]? = nil
    var stores: [DiskRecord]? = nil
    var volumes: [DiskRecord]? = nil
    var content: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "DeviceIdentifier", name = "VolumeName", mount = "MountPoint", size = "Size"
        case partitions = "Partitions", stores = "APFSPhysicalStores", volumes = "APFSVolumes"
        case content = "Content"
    }

    var isContainer: Bool { stores != nil || volumes != nil || content == "Apple_APFS_Container" }

    var visibleName: String? {
        guard let mount, !mount.hasPrefix("/System/Volumes/") else { return nil }
        return name ?? URL(fileURLWithPath: mount).lastPathComponent
    }
}

struct Hardware {
    let attachment: UInt64
    let name: String?
    let kind: InventoryRow.Kind
    var bus: String? = nil
}

public enum DriveIcon {
    case external, thumbDrive, enclosure, diskImage, network, internalDisk

    init(kind: InventoryRow.Kind, bus: String?, model: String?) {
        switch kind {
        case .image, .simulatorImage: self = .diskImage
        case .network: self = .network
        case .internalDisk: self = .internalDisk
        case .external where bus == "Thunderbolt" || model?.localizedCaseInsensitiveContains("enclosure") == true:
            self = .enclosure
        case .external where bus == "USB":
            let name = model?.lowercased() ?? ""
            self = name.contains("flash drive") || name.contains("thumb drive") ? .thumbDrive : .external
        default: self = .external
        }
    }
}

public struct InventoryRow: Identifiable {
    public enum Kind: String {
        case drive = "Drive", internalDisk = "Internal", external = "External"
        case image = "Disk image", simulatorImage = "Simulator disk image", network = "Network share"
    }
    public enum Reason: String {
        case startup = "Startup disk"
        case internalDisk = "Internal drive"
        case apfs = "Protection is unavailable for this APFS configuration."
        case partitioned = "Protection for partitioned drives is unavailable."
        case ambiguous = "Backing drive could not be verified."
        case unmounted = "No mounted volume."
        case unsupported = "This volume or connection is unsupported."
        case share = "Network shares are read-only here."
    }

    public let id: String
    public internal(set) var apfsTarget: APFSProtectionTarget? = nil
    var identity: IdentityEvidence? = nil
    var restoreTarget: RestoreTarget? = nil
    public let attachment: UInt64?
    public let name: String
    public let icon: DriveIcon
    public let kind: Kind
    public let volumes: [String]
    public let capacity: Int64?
    public let reason: Reason

    private static func isSimulatorMount(_ path: String) -> Bool {
        if path.hasPrefix("/Library/Developer/CoreSimulator/") { return true }
        let mount = URL(fileURLWithPath: path)
        let parent = mount.deletingLastPathComponent().path
        return ["/private/var/run/com.apple.security.cryptexd/mnt", "/var/run/com.apple.security.cryptexd/mnt"].contains(parent)
            && mount.lastPathComponent.hasPrefix("com.apple.") && mount.lastPathComponent.contains(".SimulatorRuntime-")
    }

    static func group(_ disks: [DiskRecord], hardware: [String: Hardware], startupWhole: String?, testImageID: UInt64? = nil) -> [Self] {
        let devices = disks.filter { !$0.isContainer }
        var parents: [String: Set<String>] = [:]
        for device in devices {
            for record in [device] + (device.partitions ?? []) {
                parents[record.id, default: []].insert(device.id)
            }
        }
        var containers: [String: [DiskRecord]] = [:]
        var rows: [Self] = []
        for container in disks where container.isContainer {
            let stores = container.stores ?? []
            let owners = stores.flatMap { parents[$0.id] ?? [] }
            if !stores.isEmpty, stores.allSatisfy({ parents[$0.id]?.count == 1 }),
               let owner = owners.first, Set(owners).count == 1 {
                containers[owner, default: []].append(container)
            } else {
                let names = (container.volumes ?? []).compactMap(\.visibleName).sorted()
                if !names.isEmpty || container.id == startupWhole {
                    rows.append(Self(id: container.id, attachment: nil, name: names.first ?? "APFS container",
                                     icon: .external, kind: .drive, volumes: names, capacity: nil,
                                     reason: container.id == startupWhole ? .startup : .ambiguous))
                }
            }
        }
        for device in devices {
            let info = hardware[device.id]
            let backed = containers[device.id] ?? []
            let records = [device] + (device.partitions ?? []) + backed.flatMap { $0.volumes ?? [] }
            let names = records.compactMap(\.visibleName).sorted()
            let startup = device.id == startupWhole || backed.contains { $0.id == startupWhole }
                || records.contains { $0.mount == "/" }
            var kind = info?.kind ?? .drive
            let mounts = records.compactMap(\.mount)
            if kind == .image {
                guard !mounts.isEmpty || (testImageID != nil && info?.attachment == testImageID) else { continue }
                if !mounts.isEmpty && mounts.allSatisfy(isSimulatorMount) {
                    kind = .simulatorImage
                }
            }
            let reason: Reason
            if startup { reason = .startup }
            else if kind == .internalDisk { reason = .internalDisk }
            else if !backed.isEmpty { reason = .apfs }
            else if !(device.partitions ?? []).isEmpty { reason = .partitioned }
            else if mounts.isEmpty { reason = .unmounted }
            else { reason = .unsupported }
            let rootName = records.first { $0.mount == "/" }?.visibleName
            let volumeNames = backed.flatMap { $0.volumes ?? [] }.compactMap(\.name).sorted()
            let name = rootName ?? names.first ?? volumeNames.first ?? info?.name ?? kind.rawValue
            rows.append(Self(id: device.id, attachment: info?.attachment, name: name,
                             icon: DriveIcon(kind: kind, bus: info?.bus, model: info?.name), kind: kind,
                             volumes: names, capacity: device.size, reason: reason))
        }
        return rows
    }
}

public enum DriveInventory {
    private struct Listing: Decodable { let AllDisksAndPartitions: [DiskRecord] }

    public static func read() throws -> [InventoryRow] {
        try read(testImageID: nil)
    }

    static func read(testImageID: UInt64?, includeRestoreIdentity: Bool = false) throws -> [InventoryRow] {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        command.arguments = ["list", "-plist"]
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        let disks = try PropertyListDecoder().decode(Listing.self, from: data).AllDisksAndPartitions
        var hardware: [String: Hardware] = [:]
        var startup: String?
        let session = DASessionCreate(nil)
        if let session {
            let root = URL(fileURLWithPath: "/", isDirectory: true)
            if let disk = DADiskCreateFromVolumePath(nil, session, root as CFURL),
               let whole = DADiskCopyWholeDisk(disk), let name = DADiskGetBSDName(whole) {
                startup = String(cString: name)
            }
            for device in disks where !device.isContainer {
                guard let disk = DADiskCreateFromBSDName(nil, session, device.id),
                      let media = Media(disk) else { continue }
                let internalFlag = media.description[kDADiskDescriptionDeviceInternalKey] as? Bool
                let kind: InventoryRow.Kind
                if media.isDiskImage { kind = .image }
                else if internalFlag == true { kind = .internalDisk }
                else if internalFlag == false { kind = .external }
                else { kind = .drive }
                let name = media.description[kDADiskDescriptionDeviceModelKey] as? String
                hardware[device.id] = Hardware(attachment: media.id, name: name, kind: kind,
                                               bus: media.description[kDADiskDescriptionDeviceProtocolKey] as? String)
            }
        }
        var rows = InventoryRow.group(disks, hardware: hardware, startupWhole: startup, testImageID: testImageID)
        if let session {
            let devices = Dictionary(disks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let owners = startupOwners(in: disks, startup: startup)
            for index in rows.indices {
                let id = rows[index].id
                guard let device = devices[id], let info = hardware[id] else { continue }
                if rows[index].reason == .apfs {
                    rows[index].apfsTarget = APFSProtectionTarget.resolve(device, disks: disks, startupWhole: startup,
                                                                         session: session, hardware: info, testImageID: testImageID)
                }
                if includeRestoreIdentity {
                    identify(&rows[index], device: device, startupOwners: owners, session: session)
                }
            }
        }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeLocalizedNameKey]
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                           options: .skipHiddenVolumes) ?? []
        for mount in mounts {
            guard let info = try? mount.resourceValues(forKeys: keys), info.volumeIsLocal == false else { continue }
            let name = info.volumeLocalizedName ?? mount.lastPathComponent
            rows.append(InventoryRow(id: mount.path, attachment: nil, name: name, icon: .network, kind: .network,
                                     volumes: [name], capacity: nil, reason: .share))
        }
        return rows.sorted {
            if ($0.reason == .startup) != ($1.reason == .startup) { return $0.reason == .startup }
            return ($0.name, $0.id) < ($1.name, $1.id)
        }
    }
}
