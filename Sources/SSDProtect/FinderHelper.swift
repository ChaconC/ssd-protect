import DriveArbitration
import Foundation
import Security
import ServiceManagement
import SystemConfiguration

@objc protocol FinderMountService {
    func update(attachment: UInt64, member: UInt64, volume: String, set: Bool, reply: @escaping (String?) -> Void)
}

// launchd runs the same signed executable as the client. Pinning its code hash also
// authenticates ad-hoc development builds without trusting a bundle identifier alone.
final class FinderHelper: NSObject, NSXPCListenerDelegate, FinderMountService {
    static let name = "com.github.ChaconC.SSDProtect.FinderMount"
    static var service: SMAppService { .daemon(plistName: name + ".plist") }
    private let work = DispatchQueue(label: name + ".updates")

    static func peerRequirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as NSDictionary?)?[kSecCodeInfoUnique] as? Data,
              hash.count == 20 else { throw Failure("Couldn’t verify the SSD Protect signature.") }
        let requirement = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled, SecCodeCheckValidity(code, [], compiled) == errSecSuccess else {
            throw Failure("SSD Protect changed on disk. Reopen the installed app.")
        }
        return requirement
    }

    static func serve() throws -> Never {
        guard geteuid() == 0 else { throw Failure("Launch the Finder helper through System Settings approval.") }
        let listener = NSXPCListener(machServiceName: name)
        listener.setConnectionCodeSigningRequirement(try peerRequirement())
        let delegate = FinderHelper()
        listener.delegate = delegate
        listener.resume()
        return withExtendedLifetime((listener, delegate)) { dispatchMain() }
    }

    private static func consoleUser() -> uid_t? {
        var uid: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil, uid != 0 else { return nil }
        return uid
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == Self.consoleUser() else { return false }
        connection.exportedInterface = NSXPCInterface(with: FinderMountService.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func update(attachment: UInt64, member: UInt64, volume: String, set: Bool, reply: @escaping (String?) -> Void) {
        let caller = NSXPCConnection.current()?.effectiveUserIdentifier
        work.async {
            guard let caller, caller == Self.consoleUser(), let uuid = UUID(uuidString: volume) else {
                reply("The user session or volume identity changed.")
                return
            }
            do {
                try APFSProtectionTarget.updateEncryptedFinderFlag(attachment: attachment, member: member, volume: uuid, set: set)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }

    // The caller runs on a background queue independent of approval callbacks.
    static func request(_ target: APFSProtectionTarget, set: Bool) throws {
        guard service.status == .enabled else { throw Failure("Approve the Finder helper in System Settings → Login Items & Extensions.") }
        guard let identity = target.encryptedIdentity else { throw Failure("The encrypted volume is unavailable.") }
        let connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.setCodeSigningRequirement(try peerRequirement())
        connection.remoteObjectInterface = NSXPCInterface(with: FinderMountService.self)
        connection.resume()
        defer { connection.invalidate() }
        try request(connection, attachment: target.id, member: identity.member, volume: identity.volume,
                    set: set, timeout: 15)
    }

    static func request(_ connection: NSXPCConnection, attachment: UInt64, member: UInt64,
                        volume: UUID, set: Bool, timeout: TimeInterval) throws {
        let reply = PendingReply()
        let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) }
        guard let helper = proxy as? FinderMountService else { throw Failure("Couldn’t connect to the Finder helper.") }
        helper.update(attachment: attachment, member: member, volume: volume.uuidString, set: set) { message in
            if let message { reply.finish(.failure(Failure(message))) } else { reply.finish(.success(())) }
        }
        try reply.wait(timeout: timeout)
    }

    // Each XPC call owns its reply. A late reply cannot complete a subsequent call.
    private final class PendingReply {
        private let condition = NSCondition()
        private var result: Result<Void, Error>?

        func finish(_ value: Result<Void, Error>) {
            condition.lock()
            defer { condition.unlock() }
            guard result == nil else { return }
            result = value
            condition.signal()
        }

        func wait(timeout: TimeInterval) throws {
            let deadline = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while result == nil {
                if !condition.wait(until: deadline), result == nil {
                    throw Failure("The Finder helper timed out. The mount state is unverified.")
                }
            }
            try result?.get()
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
