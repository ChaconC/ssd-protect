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
}

public struct InventoryRow: Identifiable {
    public enum Kind: String { case drive = "Drive", internalDisk = "Internal", external = "External", image = "Disk image", network = "Network share" }
    public enum Reason: String {
        case startup = "Startup disk"
        case internalDisk = "Internal drive"
        case apfs = "Protection for APFS containers is unavailable."
        case partitioned = "Protection for partitioned drives is unavailable."
        case ambiguous = "Backing drive could not be verified."
        case unmounted = "No mounted volume."
        case unsupported = "This volume or connection is unsupported."
        case share = "Network shares are read-only here."
    }

    public let id: String
    public let attachment: UInt64?
    public let name: String
    public let kind: Kind
    public let volumes: [String]
    public let capacity: Int64?
    public let reason: Reason

    static func group(_ disks: [DiskRecord], hardware: [String: Hardware], startupWhole: String?) -> [Self] {
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
                                     kind: .drive, volumes: names, capacity: nil,
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
            let kind = info?.kind ?? .drive
            let mounted = records.contains { $0.mount != nil }
            if kind == .image && !mounted { continue }
            let reason: Reason
            if startup { reason = .startup }
            else if kind == .internalDisk { reason = .internalDisk }
            else if !backed.isEmpty { reason = .apfs }
            else if !(device.partitions ?? []).isEmpty { reason = .partitioned }
            else if !mounted { reason = .unmounted }
            else { reason = .unsupported }
            let rootName = records.first { $0.mount == "/" }?.visibleName
            let name = rootName ?? names.first ?? info?.name ?? kind.rawValue
            rows.append(Self(id: device.id, attachment: info?.attachment, name: name, kind: kind,
                             volumes: names, capacity: device.size, reason: reason))
        }
        return rows
    }
}

public enum DriveInventory {
    private struct Listing: Decodable { let AllDisksAndPartitions: [DiskRecord] }

    public static func read() throws -> [InventoryRow] {
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
        if let session = DASessionCreate(nil) {
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
                hardware[device.id] = Hardware(attachment: media.id, name: name, kind: kind)
            }
        }
        var rows = InventoryRow.group(disks, hardware: hardware, startupWhole: startup)
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeLocalizedNameKey]
        let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                           options: .skipHiddenVolumes) ?? []
        for mount in mounts {
            guard let info = try? mount.resourceValues(forKeys: keys), info.volumeIsLocal == false else { continue }
            let name = info.volumeLocalizedName ?? mount.lastPathComponent
            rows.append(InventoryRow(id: mount.path, attachment: nil, name: name, kind: .network,
                                     volumes: [name], capacity: nil, reason: .share))
        }
        return rows.sorted {
            if ($0.reason == .startup) != ($1.reason == .startup) { return $0.reason == .startup }
            return ($0.name, $0.id) < ($1.name, $1.id)
        }
    }
}
