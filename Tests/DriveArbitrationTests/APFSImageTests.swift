import DiskArbitration
import XCTest
@testable import DriveArbitration

private final class DiskReply {
    var status: DAReturn?

    static let callback: DADiskUnmountCallback = { _, dissenter, context in
        let reply = Unmanaged<DiskReply>.fromOpaque(context!).takeRetainedValue()
        reply.status = dissenter.map(DADissenterGetStatus) ?? 0
    }
}

final class APFSImageTests: XCTestCase {
    // Supply the exact mount path of one volume on a disposable, two-volume GPT/APFS image.
    // The test ends by ejecting the image. Reattach it before running the test again.
    func testProtectionVetoesSiblingsAndSurvivesBusyConfirmedEject() throws {
        try exerciseImage(variable: "SSD_PROTECT_TEST_APFS_IMAGE", forceRetry: false)
    }

    func testForceEjectRejectsStaleTopologyThenEjectsBusyImage() throws {
        try exerciseImage(variable: "SSD_PROTECT_TEST_FORCE_APFS_IMAGE", forceRetry: true)
    }

    private func exerciseImage(variable: String, forceRetry: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) to a disposable APFS image volume's mount path.")
        }
        let session = try XCTUnwrap(DASessionCreate(nil))
        DASessionSetDispatchQueue(session, .main)
        defer { DASessionSetDispatchQueue(session, nil) }

        // Check DiskImages' live attachment independently of the application's topology resolver.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        command.arguments = ["info", "-plist"]
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { return XCTFail("Could not verify the disk image.") }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let images = try XCTUnwrap(plist?["images"] as? [[String: Any]])
        let attachments = images.compactMap { $0["system-entities"] as? [[String: Any]] }
            .filter { $0.contains { $0["mount-point"] as? String == path } }
        guard attachments.count == 1, let entities = attachments.first else {
            return XCTFail("Expected one disk image mounted at the given path.")
        }
        let whole = try XCTUnwrap(entities.first { $0["content-hint"] as? String == "GUID_partition_scheme" })
        let devicePath = try XCTUnwrap(whole["dev-entry"] as? String)
        let bsd = URL(fileURLWithPath: devicePath).lastPathComponent
        let volumeName = URL(fileURLWithPath: path).lastPathComponent
        let matches = try DriveInventory.read().filter {
            $0.kind == .image && $0.id == bsd && $0.volumes.contains(volumeName)
        }
        guard matches.count == 1, let image = matches.first else {
            return XCTFail("Could not verify one physical disk-image attachment for the requested mount.")
        }
        XCTAssertNil(image.apfsTarget, "The ordinary inventory must keep APFS disk images ineligible.")
        let imageID = try XCTUnwrap(image.attachment)
        let row = try XCTUnwrap(DriveInventory.read(testImageID: imageID).first { $0.attachment == imageID })
        let target = try XCTUnwrap(row.apfsTarget)
        let mounts = entities.compactMap { entity -> (String, String)? in
            guard let mount = entity["mount-point"] as? String,
                  let device = entity["dev-entry"] as? String else { return nil }
            return (mount, URL(fileURLWithPath: device).lastPathComponent)
        }
        guard mounts.count == 2, Set(mounts.map { URL(fileURLWithPath: $0.0).lastPathComponent }) == Set(row.volumes) else {
            return XCTFail("The disposable fixture must contain exactly two mounted APFS volumes.")
        }

        func verifiedDisk(at mount: String, bsd: String) throws -> DADisk {
            let url = URL(fileURLWithPath: mount, isDirectory: true)
            let disk = try XCTUnwrap(DADiskCreateFromVolumePath(nil, session, url as CFURL))
            let media = try XCTUnwrap(Media(disk))
            guard media.bsd == bsd, target.members[bsd] == media.id,
                  media.description[kDADiskDescriptionVolumeKindKey] as? String == "apfs",
                  (media.description[kDADiskDescriptionVolumePathKey] as? URL)?.path == mount else {
                throw NSError(domain: "APFSImageTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Disk image volume changed."])
            }
            return disk
        }

        var state = Inventory()
        let service = Arbitrator(testImageID: imageID) { state = $0 }
        service.start()
        defer { withExtendedLifetime(service) {} }
        service.protect(target, enabled: true)
        guard waitUntil({ state.protected.contains(imageID) }) else {
            return XCTFail("The disposable APFS image was not enrolled. \(state.message)")
        }

        for (mount, bsd) in mounts {
            let disk = try verifiedDisk(at: mount, bsd: bsd)
            let id = try XCTUnwrap(Media.attachmentID(disk))
            let reply = DiskReply()
            DADiskUnmount(disk, 0, DiskReply.callback, Unmanaged.passRetained(reply).toOpaque())
            guard waitUntil({ reply.status != nil && state.message.contains("Blocked an ordinary unmount") }),
                  reply.status == Int32(truncatingIfNeeded: kDAReturnNotPermitted) else {
                return XCTFail("Expected an unmount veto for each APFS sibling. \(state.message)")
            }
            XCTAssertEqual(try Media.attachmentID(verifiedDisk(at: mount, bsd: bsd)), id)
            XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(atPath: mount))
        }

        let wholeDisk = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, bsd))
        let wholeMedia = try XCTUnwrap(Media(wholeDisk))
        guard wholeMedia.id == imageID, target.members[bsd] == imageID, wholeMedia.isDiskImage,
              wholeMedia.description[kDADiskDescriptionMediaWholeKey] as? Bool == true else {
            return XCTFail("The physical disk-image attachment changed before the eject request.")
        }
        let eject = DiskReply()
        DADiskEject(wholeDisk, 0, DiskReply.callback, Unmanaged.passRetained(eject).toOpaque())
        guard waitUntil({ eject.status != nil && state.message.contains("Blocked an ordinary eject") }),
              eject.status == Int32(truncatingIfNeeded: kDAReturnNotPermitted) else {
            return XCTFail("Expected an eject veto for the verified physical image. \(state.message)")
        }
        for (mount, bsd) in mounts {
            _ = try verifiedDisk(at: mount, bsd: bsd)
            XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(atPath: mount))
        }

        service.protect(target, enabled: false)
        guard waitUntil({ !state.protected.contains(imageID) }) else {
            return XCTFail("The disposable APFS image remained protected. \(state.message)")
        }
        let (mount, volumeBSD) = try XCTUnwrap(mounts.first { $0.0 == path })
        let disk = try verifiedDisk(at: mount, bsd: volumeBSD)
        let volumeID = try XCTUnwrap(Media.attachmentID(disk))
        let unmount = DiskReply()
        DADiskUnmount(disk, 0, DiskReply.callback, Unmanaged.passRetained(unmount).toOpaque())
        guard waitUntil({ unmount.status != nil }), unmount.status == 0 else {
            return XCTFail("Expected ordinary unmount to succeed after disabling protection.")
        }
        let unmounted = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, volumeBSD))
        let media = try XCTUnwrap(Media(unmounted))
        guard media.id == volumeID, target.members[volumeBSD] == media.id,
              media.description[kDADiskDescriptionVolumePathKey] == nil else {
            return XCTFail("The selected image volume did not unmount.")
        }
        let remount = DiskReply()
        DADiskMount(unmounted, nil, 0, DiskReply.callback, Unmanaged.passRetained(remount).toOpaque())
        guard waitUntil({ remount.status != nil }), remount.status == 0 else {
            return XCTFail("Could not remount the disposable APFS volume.")
        }
        XCTAssertEqual(try Media.attachmentID(verifiedDisk(at: mount, bsd: volumeBSD)), volumeID)

        func currentTarget() throws -> APFSProtectionTarget {
            let current = try XCTUnwrap(DriveInventory.read(testImageID: imageID).first { $0.attachment == imageID })
            return try XCTUnwrap(current.apfsTarget)
        }
        let confirmed = try currentTarget()
        let expectedMounts = Dictionary(uniqueKeysWithValues: mounts.map { ($0.1, $0.0) })
        guard confirmed.mountedVolumes.mapValues(\.path) == expectedMounts else {
            return XCTFail("Confirmation must include both verified image mounts.")
        }
        service.protect(confirmed, enabled: true)
        guard waitUntil({ state.protected.contains(imageID) }) else {
            return XCTFail("Could not re-enroll the disposable image. \(state.message)")
        }

        if forceRetry {
            // Simulate a stale physical attachment at the same BSD name and mount paths.
            let previousID = UInt64.max
            var members = confirmed.members
            members[confirmed.wholeBSD] = previousID
            let stale = APFSProtectionTarget(id: previousID, wholeBSD: confirmed.wholeBSD,
                                             members: members, containers: confirmed.containers,
                                             mountedVolumes: confirmed.mountedVolumes)
            service.forceEject(stale)
            guard waitUntil({ !state.busy && state.message.contains("state changed") }) else {
                return XCTFail("Force eject must reject an attachment that was replaced.")
            }
            XCTAssertEqual(try currentTarget(), confirmed)
            XCTAssertTrue(state.protected.contains(imageID))
        }

        // Hold the last volume so a normal eject can partially unmount the image.
        let (busyPath, busyBSD) = try XCTUnwrap(mounts.max { $0.1 < $1.1 })
        _ = try verifiedDisk(at: busyPath, bsd: busyBSD)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["120"]
        holder.currentDirectoryURL = URL(fileURLWithPath: busyPath, isDirectory: true)
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }
        service.ejectConfirmed(confirmed)
        guard waitUntil(timeout: 35, { !state.busy && state.message.contains("drive is busy") }) else {
            return XCTFail("Expected the confirmed normal unmount to report busy. \(state.message)")
        }
        let busyMessage = state.message
        XCTAssertTrue(state.protected.contains(imageID))
        holder.terminate()
        holder.waitUntilExit()

        // A whole-volume request may have already unmounted the non-busy sibling.
        // Check the veto after releasing the holder so busy cannot explain the rejection.
        let protectedDisk = try verifiedDisk(at: busyPath, bsd: busyBSD)
        let denied = DiskReply()
        DADiskUnmount(protectedDisk, 0, DiskReply.callback, Unmanaged.passRetained(denied).toOpaque())
        guard waitUntil({ denied.status != nil && state.message.contains("Blocked an ordinary unmount") }),
              denied.status == Int32(truncatingIfNeeded: kDAReturnNotPermitted) else {
            return XCTFail("Ordinary unmount must still be vetoed after a busy failure. \(state.message)")
        }
        _ = try verifiedDisk(at: busyPath, bsd: busyBSD)

        var remainingMounts: [String: String] = [:]
        for (path, name) in mounts {
            let sibling = try XCTUnwrap(DADiskCreateFromBSDName(nil, session, name))
            let media = try XCTUnwrap(Media(sibling))
            guard media.id == confirmed.members[name] else { return XCTFail("The image attachment changed.") }
            if media.description[kDADiskDescriptionVolumePathKey] != nil {
                _ = try verifiedDisk(at: path, bsd: name)
                XCTAssertTrue(busyMessage.contains(path), "Busy result omitted a mounted volume.")
                remainingMounts[name] = path
            }
        }
        let retry = try currentTarget()
        guard retry.mountedVolumes.mapValues(\.path) == remainingMounts,
              remainingMounts[busyBSD] == busyPath else {
            return XCTFail("The retry confirmation did not describe the current mounted volumes.")
        }
        var secondHolder: Process?
        defer {
            if let secondHolder, secondHolder.isRunning {
                secondHolder.terminate()
                secondHolder.waitUntilExit()
            }
        }
        if forceRetry {
            // Keep the volume busy through the verified force request.
            let busyHolder = Process()
            busyHolder.executableURL = URL(fileURLWithPath: "/bin/sleep")
            busyHolder.arguments = ["120"]
            busyHolder.currentDirectoryURL = URL(fileURLWithPath: busyPath, isDirectory: true)
            try busyHolder.run()
            secondHolder = busyHolder
            XCTAssertNotEqual(confirmed, retry)
            service.forceEject(confirmed)
            guard waitUntil({ !state.busy && state.message.contains("state changed") }) else {
                return XCTFail("A stale force request must stop before unmounting.")
            }
            XCTAssertTrue(state.protected.contains(imageID))
            _ = try verifiedDisk(at: busyPath, bsd: busyBSD)
            service.forceEject(retry)
        } else {
            service.ejectConfirmed(retry)
        }
        guard waitUntil(timeout: 35, { !state.busy && state.message.hasPrefix("Ejected ") }) else {
            return XCTFail("Expected the verified retry to eject the image. \(state.message)")
        }
        XCTAssertTrue(waitUntil {
            DADiskCreateFromBSDName(nil, session, bsd).flatMap(Media.attachmentID) != imageID
        }, "The physical image attachment remained present after eject.")
        for (path, _) in mounts {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "An image mount remained after eject.")
        }
    }

    private func waitUntil(timeout: TimeInterval = 10, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }
}
