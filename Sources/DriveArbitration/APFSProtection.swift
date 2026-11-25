import DiskArbitration
import Foundation
import IOKit

/// A connection-scoped physical attachment and its verified Disk Arbitration aliases.
public struct APFSProtectionTarget: Equatable {
    public let id: UInt64
    let wholeBSD: String
    var members: [String: UInt64]
    let containers: Set<UInt64>

    func covers(_ bsd: String, observed: UInt64?) -> Bool {
        guard let observed else { return false }
        return members[bsd] == observed
    }

    static func memberNames(of device: DiskRecord, disks: [DiskRecord], startupWhole: String?) -> Set<String>? {
        guard let startupWhole, disks.contains(where: { $0.id == startupWhole }),
              device.id != startupWhole, !device.isContainer else { return nil }
        let physical = [device] + (device.partitions ?? [])
        let partitions = Set(physical.map(\.id))
        var attachedStores: Set<String> = []
        var names = partitions
        for container in disks where container.isContainer {
            let stores = Set((container.stores ?? []).map(\.id))
            guard !stores.isDisjoint(with: partitions) else { continue }
            // Multi-store containers and boot containers cannot be claimed by one drive.
            guard stores.count == 1, container.id != startupWhole,
                  (container.volumes ?? []).allSatisfy({ $0.mount != "/" }) else { return nil }
            attachedStores.formUnion(stores)
            names.insert(container.id)
            names.formUnion((container.volumes ?? []).map(\.id))
        }
        // An APFS partition missing its container makes the mapping incomplete.
        let declaredStores = physical.filter { $0.content?.hasPrefix("Apple_APFS") == true }
        guard !attachedStores.isEmpty, declaredStores.allSatisfy({ attachedStores.contains($0.id) }),
              physical.allSatisfy({ $0.mount != "/" }) else { return nil }
        return names
    }

    static func resolve(_ device: DiskRecord, disks: [DiskRecord], startupWhole: String?, session: DASession,
                        hardware: Hardware, testImageID: UInt64?) -> Self? {
        guard hardware.kind == .external || (hardware.kind == .image && hardware.attachment == testImageID),
              let aliases = memberNames(of: device, disks: disks, startupWhole: startupWhole),
              let root = DADiskCreateFromBSDName(nil, session, device.id), let media = Media(root),
              media.id == hardware.attachment, media.description[kDADiskDescriptionMediaWholeKey] as? Bool == true
        else { return nil }
        if hardware.kind == .external {
            // Thunderbolt NVMe can report PCI-Express at the Disk Arbitration layer.
            guard media.description[kDADiskDescriptionDeviceInternalKey] as? Bool == false,
                  let bus = media.description[kDADiskDescriptionDeviceProtocolKey] as? String,
                  ["USB", "Thunderbolt", "PCI-Express", "FireWire"].contains(bus) else { return nil }
        }
        var members: [String: UInt64] = [:]
        for name in aliases {
            guard let disk = DADiskCreateFromBSDName(nil, session, name),
                  let id = memberID(disk, under: media.id) else { return nil }
            members[name] = id
        }
        let containers = Set(disks.filter(\.isContainer).compactMap { members[$0.id] })
        return Self(id: media.id, wholeBSD: device.id, members: members, containers: containers)
    }

    // An APFS sibling can appear between inventory scans. Bind it on the serial
    // appearance callback only when both its container and physical attachment match.
    mutating func observe(_ media: Media) {
        guard members[media.bsd] != media.id,
              let whole = DADiskCopyWholeDisk(media.disk), let container = Media.attachmentID(whole),
              containers.contains(container), Self.memberID(media.disk, under: id) == media.id else { return }
        members[media.bsd] = media.id
    }

    // Verify the independently enumerated BSD names against a single live registry lineage.
    private static func memberID(_ disk: DADisk, under root: UInt64) -> UInt64? {
        var entry = DADiskCopyIOMedia(disk)
        var first: UInt64?
        while entry != 0 {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                return nil
            }
            if first == nil { first = id }
            if id == root {
                IOObjectRelease(entry)
                return first
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }
}
