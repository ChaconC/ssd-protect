import XCTest
@testable import DriveArbitration

final class InventoryTests: XCTestCase {
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
}
