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
              let target = try DriveInventory.read(testImageID: nil, includeNetworkShares: false).compactMap(\.apfsTarget).first(where: { $0.id == attachment }),
              let identity = target.encryptedIdentity, identity.member == member, identity.volume == volume,
              let path = target.encryptedFinderVolume, let bsd = target.mountedVolumes.first?.key else {
            throw FinderUpdateError.changed
        }
        let fd = try FinderMount.openForVerification(path)
        defer { close(fd) }
        var mount = statfs()
        guard fstatfs(fd, &mount) == 0,
              let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, path as CFURL),
              Self.memberID(disk, under: attachment) == member,
              FinderMount.flags(at: path) == mount.f_flags else { throw FinderUpdateError.changed }
        guard FinderMount.supports(flags: mount.f_flags) else { throw FinderUpdateError.unsupported }
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
              try DriveInventory.read(testImageID: nil, includeNetworkShares: false).contains(where: { $0.apfsTarget == target }) else { throw FinderUpdateError.verification }
    }
}

private enum FinderUpdateError: LocalizedError {
    case changed, unsupported, verification, command, access(Int32)
    var errorDescription: String? {
        switch self {
        case .changed: return "The helper couldn’t match the current encrypted mount to the selected drive."
        case .unsupported: return "The helper can’t preserve all options on this mount."
        case .access(let code): return "macOS denied access to the mount metadata or the volume is unavailable (\(String(cString: strerror(code))))."
        case .verification: return "The command finished, but the mount flags or drive identity could not be verified."
        case .command: return "macOS declined the in-place mount update."
        }
    }
}

extension FinderMount {
    // Pin the directory for fstatfs without requesting permission to enumerate its contents.
    static func openForVerification(_ path: URL) throws -> Int32 {
        let fd = open(path.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FinderUpdateError.access(errno) }
        return fd
    }
}
