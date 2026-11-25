import Foundation
import XCTest
@testable import SSDProtect

final class FinderHelperTests: XCTestCase {
    // Exercise the peer requirement and wire types without installing a service or accessing any disk.
    func testSignedPeerCanSendOnlyTheMountRequest() throws {
        try exerciseConnection(matching: true)
    }

    func testMismatchedSignatureIsRefused() throws {
        try exerciseConnection(matching: false)
    }

    func testUnansweredRequestTimesOutAndNextRequestHasItsOwnReply() throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Probe()
        let received = expectation(description: "Helper accepted the stalled call")
        delegate.onStall = { received.fulfill() }
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: FinderMountService.self)
        connection.resume()
        defer { connection.invalidate() }
        try withExtendedLifetime(delegate) {
            XCTAssertThrowsError(try FinderHelper.request(connection, attachment: 1, member: 2,
                                                          volume: UUID(), set: false, timeout: 0.2)) {
                XCTAssertTrue($0.localizedDescription.contains("timed out"))
            }
            wait(for: [received], timeout: 2)
            try FinderHelper.request(connection, attachment: 1, member: 2, volume: UUID(), set: true, timeout: 2)
        }
    }

    private func exerciseConnection(matching: Bool) throws {
        let listener = NSXPCListener.anonymous()
        let delegate = Probe()
        let requirement = try FinderHelper.peerRequirement()
        listener.setConnectionCodeSigningRequirement(matching ? requirement : "cdhash H\"0000000000000000000000000000000000000000\"")
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: FinderMountService.self)
        connection.resume()
        defer { connection.invalidate() }
        let completed = expectation(description: "Mount request answered or rejected")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            XCTAssertFalse(matching)
            completed.fulfill()
        }
        let helper = try XCTUnwrap(proxy as? FinderMountService)
        helper.update(attachment: 4, member: 8, volume: "test", set: true) { response in
            XCTAssertTrue(matching)
            XCTAssertEqual(response, "4/8/test/true")
            completed.fulfill()
        }
        withExtendedLifetime(delegate) { wait(for: [completed], timeout: 5) }
    }

    private final class Probe: NSObject, NSXPCListenerDelegate, FinderMountService {
        var onStall: (() -> Void)?
        private var stalled: ((String?) -> Void)?

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: FinderMountService.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }

        func update(attachment: UInt64, member: UInt64, volume: String, set: Bool, reply: @escaping (String?) -> Void) {
            if let onStall {
                if set {
                    stalled?("Late error")
                    reply(nil)
                } else {
                    stalled = reply
                    onStall()
                }
                return
            }
            reply("\(attachment)/\(member)/\(volume)/\(set)")
        }
    }
}
