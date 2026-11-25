import DriveArbitration
import Foundation

enum FinderDisableScan {
    enum Failure: LocalizedError {
        case timedOut, unknown(URL)

        var errorDescription: String? {
            switch self {
            case .timedOut: return "The drive scan timed out. Some mounted volumes may still have the Finder flag set."
            case .unknown(let path): return "Couldn’t verify the Finder mount flag for \(path.lastPathComponent)."
            }
        }
    }

    static func needsRestore(flag: Bool?, at path: URL) throws -> Bool {
        guard let flag else { throw Failure.unknown(path) }
        return flag
    }

    static func readTargets() throws -> [APFSProtectionTarget] {
        try DriveInventory.read(includeNetworkShares: false).compactMap(\.apfsTarget).filter { target in
            guard let path = target.encryptedFinderVolume else { return false }
            return try needsRestore(flag: target.encryptedFinderFlag, at: path)
        }
    }

    static func start(timeout: DispatchTimeInterval = .seconds(15),
                      read: @escaping () throws -> [APFSProtectionTarget] = readTargets,
                      completion: @escaping (Result<[APFSProtectionTarget], Error>) -> Void) {
        // Both callbacks run on the main queue and compete only with this scan's deadline.
        let reply = Reply(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { reply.finish(.failure(Failure.timedOut)) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try read() }
            DispatchQueue.main.async { reply.finish(result) }
        }
    }

    private final class Reply {
        typealias Callback = (Result<[APFSProtectionTarget], Error>) -> Void
        private var callback: Callback?
        init(_ callback: @escaping Callback) { self.callback = callback }

        func finish(_ result: Result<[APFSProtectionTarget], Error>) {
            let deliver = callback
            callback = nil
            deliver?(result)
        }
    }
}
