import DiskArbitration
import Foundation

/// Mount options preserved when Disk Arbitration mounts the same APFS volume again.
enum FinderMount {
    static let restrictions: [(Int32, String)] = [
        (MNT_RDONLY, "rdonly"), (MNT_NOEXEC, "noexec"), (MNT_NOSUID, "nosuid"),
        (MNT_NODEV, "nodev"), (MNT_IGNORE_OWNERSHIP, "noowners"),
        (MNT_SYNCHRONOUS, "sync"), (MNT_ASYNC, "async"), (MNT_NOATIME, "noatime"),
        (MNT_DONTBROWSE, "nobrowse"), (MNT_QUARANTINE, "quarantine")
    ]

    static func options(flags: UInt32, hidden: Bool) -> [String] {
        restrictions.compactMap { flags & UInt32($0.0) != 0 ? $0.1 : nil }
            + (hidden ? ["automounted"] : [])
    }

    static func supports(flags: UInt32) -> Bool {
        let derived = UInt32(MNT_LOCAL | MNT_JOURNALED | MNT_DOVOLFS | MNT_MULTILABEL | MNT_AUTOMOUNTED | MNT_REMOVABLE | MNT_CPROTECT)
        let supported = restrictions.reduce(derived) { $0 | UInt32($1.0) }
        return flags & ~supported == 0
    }

    static func flags(at path: URL) -> UInt32? {
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return nil }
        let actual = withUnsafeBytes(of: &info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard actual == path.path else { return nil }
        return info.f_flags
    }

    static func mount(_ disk: DADisk, at path: URL?, flags: UInt32, hidden: Bool,
                      callback: DADiskMountCallback, context: UnsafeMutableRawPointer) {
        let values = options(flags: flags, hidden: hidden).map { $0 as CFString }
        var arguments = values.map { Optional(Unmanaged.passUnretained($0)) } + [nil]
        withExtendedLifetime(values) {
            DADiskMountWithArguments(disk, path as CFURL?, 0, callback, context, &arguments)
        }
    }
}

extension APFSProtectionTarget {
    /// A remount confirmation covers exactly one ordinary mounted volume.
    public var finderVolume: URL? {
        guard mountedVolumes.count == 1, let (bsd, path) = mountedVolumes.first,
              unencryptedMountedMembers.contains(bsd),
              path.deletingLastPathComponent().path == "/Volumes" else { return nil }
        return path
    }

    public var hasFinderMountFlag: Bool {
        guard let path = finderVolume, let flags = FinderMount.flags(at: path) else { return false }
        return flags & UInt32(MNT_AUTOMOUNTED) != 0
    }
}

/// The original flags and visible path survive a busy reply at the temporary mount.
struct FinderStagingMount {
    let original: APFSProtectionTarget
    let bsd: String
    let path: URL
    let originalFlags: UInt32

    func matches(_ current: APFSProtectionTarget) -> Bool {
        var expected = original
        expected.mountedVolumes[bsd] = path
        return current == expected
    }

    static func prepare(original: APFSProtectionTarget, bsd: String, member: UInt64, flags: UInt32) throws -> Self {
        // Finder can retain a display entry for every distinct mount point it has seen.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(".ssd-protect-remount-\(member)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return Self(original: original, bsd: bsd, path: directory.resolvingSymlinksInPath(), originalFlags: flags)
    }

    func leave(unmount: (DADiskUnmountOptions, @escaping (DADissenter?) -> Void) -> Void,
               stillMounted: @escaping (DADissenter, Self) -> Void, unmounted: @escaping () -> Void) {
        unmount(0) { dissent in
            if let dissent { stillMounted(dissent, self) } else { unmounted() }
        }
    }
}
