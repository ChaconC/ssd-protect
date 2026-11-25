import Darwin
import DiskArbitration
import Foundation
import IOKit

enum DiskUnlock {
    // Disk Utility and APFSUserAgent pass the volume's IOMedia UUID string.
    // Resolve at runtime because this interface is private to macOS.
    private typealias Prompt = @convention(c) (CFString) -> Void
    private static let prompt: Prompt? = {
        guard let library = dlopen("/usr/lib/libDiskUnlock.dylib", RTLD_LOCAL | RTLD_LAZY),
              let symbol = dlsym(library, "DUUnlockVolume") else { return nil }
        return unsafeBitCast(symbol, to: Prompt.self)
    }()

    static func request(for media: Media, completion: @escaping () -> Void) -> Bool {
        guard let prompt else { return false }
        let entry = DADiskCopyIOMedia(media.disk)
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        guard let uuid = IORegistryEntryCreateCFProperty(entry, "UUID" as CFString, nil, 0)?
            .takeRetainedValue() as? String, UUID(uuidString: uuid) != nil else { return false }
        DispatchQueue.global(qos: .userInitiated).async {
            prompt(uuid as CFString)
            completion()
        }
        return true
    }
}
