import CryptoKit
import DiskArbitration
import Foundation
import IOKit

enum RestoreTarget {
    case leaf(Drive)
    case apfs(APFSProtectionTarget)
}

extension DriveInventory {
    // A known startup container is insufficient unless every physical store
    // behind it maps to exactly one physical disk in this inventory.
    static func startupOwners(in disks: [DiskRecord], startup: String?) -> Set<String>? {
        guard let startup, disks.filter({ $0.id == startup }).count == 1,
              let root = disks.first(where: { $0.id == startup }) else { return nil }
        let physicalNames = disks.filter { !$0.isContainer }.flatMap { [$0.id] + ($0.partitions ?? []).map(\.id) }
        guard Set(physicalNames).count == physicalNames.count else { return nil }
        if !root.isContainer { return [root.id] }
        guard let stores = root.stores, !stores.isEmpty else { return nil }
        var owners: Set<String> = []
        for store in stores {
            let matches = disks.filter { disk in
                !disk.isContainer && (disk.id == store.id || disk.partitions?.contains { $0.id == store.id } == true)
            }
            guard matches.count == 1 else { return nil }
            owners.insert(matches[0].id)
        }
        return owners
    }

    static func identify(_ row: inout InventoryRow, device: DiskRecord, startupOwners: Set<String>?,
                         session: DASession) {
        guard let disk = DADiskCreateFromBSDName(nil, session, device.id), let whole = Media(disk),
              whole.id == row.attachment, row.kind == .external || row.kind == .internalDisk,
              whole.description[kDADiskDescriptionMediaWholeKey] as? Bool == true else { return }

        let mediaID: String?
        let target: RestoreTarget?
        if let leaf = whole.drive, device.partitions?.isEmpty != false, row.reason == .unsupported {
            mediaID = uuid(in: whole, key: kDADiskDescriptionVolumeUUIDKey)
            target = .leaf(leaf)
        } else {
            // A single APFS store supplies the persistent media UUID. Its BSD
            // name alone cannot establish that this partition belongs to the root.
            let stores = (device.partitions ?? []).filter { $0.content == "Apple_APFS" }
            if stores.count == 1, let part = DADiskCreateFromBSDName(nil, session, stores[0].id),
               let media = Media(part), let parent = DADiskCopyWholeDisk(part),
               Media.attachmentID(parent) == whole.id {
                mediaID = uuid(in: media, key: kDADiskDescriptionMediaUUIDKey)
                if let apfs = row.apfsTarget, apfs.covers(media.bsd, observed: media.id) { target = .apfs(apfs) }
                else { target = nil }
            } else {
                mediaID = uuid(in: whole, key: kDADiskDescriptionVolumeUUIDKey)
                target = nil
            }
        }
        row.identity = IdentityEvidence(device: hardwareKey(whole), media: mediaID)
        if row.kind == .external, row.reason != .startup, let startupOwners, !startupOwners.contains(device.id) {
            row.restoreTarget = target
        }
    }

    private static func uuid(in media: Media, key: CFString) -> String? {
        guard let value = media.description[key], CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
        let uuid = CFUUIDCreateString(nil, (value as! CFUUID)) as String
        guard uuid != "00000000-0000-0000-0000-000000000000" else { return nil }
        return digest(uuid)
    }

    private static func hardwareKey(_ media: Media) -> String? {
        if let guid = media.description[kDADiskDescriptionDeviceGUIDKey] as? Data, guid.count >= 8,
           Set(guid).count > 1 { return digest("guid:" + guid.base64EncodedString()) }
        var entry = DADiskCopyIOMedia(media.disk)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }
            if IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0 {
                let fields = IORegistryEntryCreateCFProperty(entry, "Device Characteristics" as CFString,
                                                              nil, 0)?.takeRetainedValue() as? [String: Any]
                guard let value = fields?["Serial Number"] as? String else { return nil }
                let serial = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard serial.count >= 4, Set(serial).count > 1,
                      !["UNKNOWN", "NONE", "DEFAULT", "123456789", "0123456789"].contains(serial) else { return nil }
                return digest("serial:" + serial)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }

    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}
