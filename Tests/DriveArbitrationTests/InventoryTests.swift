import XCTest
@testable import DriveArbitration

final class InventoryTests: XCTestCase {
    func testIconsUseHardwareMetadataAndNeverTheVolumeName() {
        func icon(_ kind: InventoryRow.Kind, _ bus: String?, _ model: String?) -> DriveIcon {
            let device = DiskRecord(id: "device", name: "USB Flash Drive", mount: "/Volumes/Test")
            let hardware = Hardware(attachment: 1, name: model, kind: kind, bus: bus)
            return InventoryRow.group([device], hardware: ["device": hardware], startupWhole: nil)[0].icon
        }
        XCTAssertEqual(icon(.external, "USB", nil), .external)
        XCTAssertEqual(icon(.external, "USB", "Portable SSD"), .external)
        XCTAssertEqual(icon(.external, "USB", " USB Flash Drive "), .thumbDrive)
        XCTAssertEqual(icon(.external, "Thunderbolt", nil), .enclosure)
        XCTAssertEqual(icon(.external, "USB", "NVMe Enclosure"), .enclosure)
        XCTAssertEqual(icon(.external, "PCI-Express", nil), .external)
        XCTAssertEqual(icon(.image, "Disk Image", nil), .diskImage)
    }

    func testAPFSVolumesGroupUnderOnePhysicalDiskWithoutAddingSharedCapacity() throws {
        let physical = DiskRecord(id: "physical", size: 2_000, partitions: [.init(id: "store")])
        let container = DiskRecord(id: "container", size: 1_900, stores: [.init(id: "store")],
                                   volumes: [.init(id: "a", name: "Archive", mount: "/Volumes/Archive"),
                                             .init(id: "b", name: "Work", mount: "/Volumes/Work")])
        let rows = InventoryRow.group([physical, container], hardware: [:], startupWhole: nil)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.volumes, ["Archive", "Work"])
        XCTAssertEqual(row.capacity, 2_000)
        XCTAssertEqual(row.reason, .apfs)
    }

    func testUnmountedImagesAreHiddenAndPartitionedMediaStayInformational() {
        let devices = [DiskRecord(id: "hidden"), DiskRecord(id: "visible", name: "Sample", mount: "/private/tmp/custom-mount"),
                       DiskRecord(id: "external", partitions: [.init(id: "slice", name: "Files", mount: "/Volumes/Files")])]
        let rows = InventoryRow.group(devices, hardware: [
            "hidden": Hardware(attachment: 10, name: nil, kind: .image),
            "visible": Hardware(attachment: 11, name: nil, kind: .image),
            "external": Hardware(attachment: 12, name: nil, kind: .external)
        ], startupWhole: nil)
        XCTAssertEqual(rows.map(\.id), ["visible", "external"])
        XCTAssertEqual(rows.first?.kind, .image)
        XCTAssertEqual(rows.last?.reason, .partitioned)
        XCTAssertEqual(rows.last?.volumes, ["Files"])
    }

    func testStartupSnapshotAndAmbiguousStores() {
        let startup = DiskRecord(id: "internal", partitions: [.init(id: "bootStore")])
        let boot = DiskRecord(id: "synth", stores: [.init(id: "bootStore")],
                              volumes: [.init(id: "root", name: "System", mount: "/")])
        let mixed = DiskRecord(id: "mixed", stores: [.init(id: "bootStore"), .init(id: "missing")],
                               volumes: [.init(id: "shared", name: "Shared", mount: "/Volumes/Shared")])
        let rows = InventoryRow.group([startup, boot, mixed], hardware: [:], startupWhole: "synth")
        XCTAssertEqual(rows.first { $0.id == "internal" }?.reason, .startup)
        XCTAssertEqual(rows.first { $0.id == "mixed" }?.reason, .ambiguous)
        XCTAssertEqual(rows.first { $0.id == "internal" }?.volumes, ["System"])
    }

    func testOnlyImagesMountedEntirelyAtSimulatorPathsAreGroupedAsSimulators() {
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_Runtime"
        let bundle = DiskRecord(id: "bundle", mount: "/Library/Developer/CoreSimulator/Cryptex/Images/bundle/Runtime")
        let cryptexRoot = "/private/var/run/com.apple.security.cryptexd/mnt/"
        let cryptex = DiskRecord(id: "cryptex", mount: cryptexRoot + "com.apple.iPhoneOS.SimulatorRuntime-v24.1.example")
        let otherCryptex = DiskRecord(id: "other", mount: cryptexRoot + "com.apple.Safari")
        let image = DiskRecord(id: "image", partitions: [.init(id: "store")])
        let container = DiskRecord(id: "sim", stores: [.init(id: "store")],
                                   volumes: [.init(id: "volume", name: "Runtime", mount: runtime)])
        let regular = DiskRecord(id: "regular", name: "iOS Simulator", mount: "/Volumes/iOS Simulator")
        let similar = DiskRecord(id: "similar", mount: "/Library/Developer/CoreSimulatorBackup/Volumes/Sample")
        let physical = DiskRecord(id: "physical", mount: runtime)
        let mixed = DiskRecord(id: "mixed", partitions: [.init(id: "one", mount: runtime),
                                                        .init(id: "two", mount: "/Volumes/Files")])
        let images = [bundle, cryptex, otherCryptex, image, regular, similar, mixed]
        var hardware = Dictionary(uniqueKeysWithValues: images.enumerated().map { index, disk in
            (disk.id, Hardware(attachment: UInt64(index + 1), name: nil, kind: .image))
        })
        hardware[physical.id] = Hardware(attachment: 20, name: nil, kind: .external)
        let rows = InventoryRow.group(images + [physical, container], hardware: hardware, startupWhole: nil)
        XCTAssertEqual(Set(rows.filter { $0.kind == .simulatorImage }.map(\.id)), ["image", "bundle", "cryptex"])
        XCTAssertEqual(Set(rows.filter { $0.kind == .image }.map(\.id)), ["regular", "similar", "mixed", "other"])
    }
}
