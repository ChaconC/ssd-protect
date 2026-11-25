import DiskArbitration
import Foundation

extension APFSProtectionTarget {
    public var encryptedFinderVolume: URL? {
        guard mountedVolumes.count == 1, let (bsd, path) = mountedVolumes.first,
              encryptedVolumeUUIDs[bsd] != nil,
              path.deletingLastPathComponent().path == "/Volumes",
              path.path.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return path
    }

    public var encryptedFinderFlag: Bool? {
        guard let path = encryptedFinderVolume, let flags = FinderMount.flags(at: path),
              FinderMount.supports(flags: flags) else { return nil }
        return flags & UInt32(MNT_AUTOMOUNTED) != 0
    }

    public var encryptedIdentity: (member: UInt64, volume: UUID)? {
        guard encryptedFinderVolume != nil, let bsd = mountedVolumes.first?.key,
              let member = members[bsd], let volume = encryptedVolumeUUIDs[bsd] else { return nil }
        return (member, volume)
    }

    /// The daemon derives paths, BSD names and mount options from its own live inventory.
    public static func updateEncryptedFinderFlag(attachment: UInt64, member: UInt64, volume: UUID, set: Bool) throws {
        guard geteuid() == 0,
              let target = try DriveInventory.read().compactMap(\.apfsTarget).first(where: { $0.id == attachment }),
              let identity = target.encryptedIdentity, identity.member == member, identity.volume == volume,
              let path = target.encryptedFinderVolume, let bsd = target.mountedVolumes.first?.key else {
            throw FinderUpdateError.changed
        }
        let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FinderUpdateError.changed }
        defer { close(fd) }
        var mount = statfs()
        guard fstatfs(fd, &mount) == 0,
              let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, path as CFURL),
              Self.memberID(disk, under: attachment) == member,
              FinderMount.flags(at: path) == mount.f_flags,
              FinderMount.supports(flags: mount.f_flags) else { throw FinderUpdateError.changed }
        let bit = UInt32(MNT_AUTOMOUNTED)
        let expected = set ? mount.f_flags | bit : mount.f_flags & ~bit
        guard expected != mount.f_flags else { return }

        let device = "/dev/" + bsd
        let options = FinderMount.options(flags: mount.f_flags, hidden: false) + [set ? "automounted" : "noautomounted"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = ["-u", "-t", "apfs", "-o", options.joined(separator: ","), device, path.path]
        guard let live = DADiskCreateFromBSDName(nil, session, bsd),
              Self.memberID(live, under: attachment) == member,
              FinderMount.flags(at: path) == mount.f_flags else { throw FinderUpdateError.changed }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FinderUpdateError.command }
        guard fstatfs(fd, &mount) == 0, mount.f_flags == expected,
              FinderMount.flags(at: path) == expected,
              try DriveInventory.read().contains(where: { $0.apfsTarget == target }) else { throw FinderUpdateError.verification }
    }
}

private enum FinderUpdateError: LocalizedError {
    case changed, verification, command
    var errorDescription: String? {
        switch self {
        case .changed: return "The mount or drive identity changed, or its flags are unsupported. Refresh the drive list."
        case .verification: return "The command finished, but the mount flags or drive identity could not be verified."
        case .command: return "macOS declined the in-place mount update."
        }
    }
}
