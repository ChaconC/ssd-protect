import AppKit
import Combine
import DriveArbitration
import SwiftUI

private final class MenuModel: ObservableObject {
    @Published var inventory = Inventory()
    @Published var rows: [InventoryRow] = []
    @Published var scanMessage: String? = "Reading drive inventory…"
    private let scanner = DispatchQueue(label: "SSDProtect.Inventory", qos: .utility)
    private var revision = 0
    private var scanning = false
    private var subscriptions: Set<AnyCancellable> = []
    lazy var arbitrator = Arbitrator(topologyChanged: { [weak self] in self?.refresh() }) { [weak self] state in
        self?.inventory = state
    }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.publisher(for: event).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        arbitrator.start()
        refresh()
    }

    // Main-queue events can arrive in bursts. Keep at most one scan in flight.
    func refresh() {
        revision += 1
        let requested = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.revision == requested, !self.scanning else { return }
            self.scanning = true
            self.scanner.async {
                let result = Result { try DriveInventory.read() }
                DispatchQueue.main.async {
                    self.scanning = false
                    guard self.revision == requested else { self.refresh(); return }
                    switch result {
                    case .success(let rows):
                        self.rows = rows
                        self.scanMessage = nil
                    case .failure:
                        self.rows = []
                        self.scanMessage = "Drive inventory unavailable."
                    }
                }
            }
        }
    }

    func confirm(_ drive: Drive) {
        let alert = NSAlert()
        alert.messageText = "Eject \(drive.name)?"
        alert.informativeText = "Save your work and stop transfers on \(drive.mount.path) before ejecting this drive."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Eject").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { arbitrator.ejectConfirmed(drive) }
    }
}

@main
struct SSDProtectApp: App {
    @StateObject private var model = MenuModel()
    @State private var showsSimulatorImages = false

    var body: some Scene {
        MenuBarExtra("SSD Protect", systemImage: protectedCount > 0 ? "externaldrive.badge.checkmark" : "externaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                Text("SSD Protect").font(.headline)
                Text(protectionStatus).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let rows = inventoryRows
                        let simulators = rows.filter { $0.kind == .simulatorImage }
                        ForEach(model.inventory.drives) { drive in
                            VStack(alignment: .leading) {
                                Toggle(drive.name, isOn: Binding(
                                    get: { model.inventory.protected.contains(drive.id) },
                                    set: { model.arbitrator.protect(drive, enabled: $0) }
                                )).toggleStyle(.switch)
                                HStack {
                                    Text(drive.transport).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Eject…") { model.confirm(drive) }
                                }
                            }.disabled(model.inventory.busy)
                            Divider()
                        }
                        ForEach(rows.filter { $0.kind != .simulatorImage }) { row in
                            inventoryRow(row)
                            Divider()
                        }
                        if !simulators.isEmpty {
                            DisclosureGroup("Simulator disk images (\(simulators.count))", isExpanded: $showsSimulatorImages) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(simulators) { row in inventoryRow(row) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                            }
                        }
                        if let message = model.scanMessage {
                            Text(message).foregroundStyle(.secondary)
                        } else if rows.isEmpty && model.inventory.drives.isEmpty {
                            Text("No drives to show.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 370)
                .fixedSize(horizontal: false, vertical: true)
                if !model.inventory.message.isEmpty { Text(model.inventory.message).font(.callout) }
                Button("Quit and Stop Protection") { NSApp.terminate(nil) }
            }
            .padding()
            .frame(width: 340)
            .onAppear { model.refresh() }
        }
        .menuBarExtraStyle(.window)
    }

    private var protectedCount: Int {
        model.inventory.protected.count
    }

    private var protectionStatus: String {
        guard let available = model.inventory.available else { return "Starting protection…" }
        guard available else { return "Protection unavailable" }
        return protectedCount == 0 ? "No drives protected" : "Protecting \(protectedCount) \(protectedCount == 1 ? "drive" : "drives")"
    }

    private var inventoryRows: [InventoryRow] {
        let eligible = Set(model.inventory.drives.map(\.id))
        return model.rows.filter { row in
            row.reason != .startup && !(row.attachment.map(eligible.contains) ?? false)
        }
    }

    private func inventoryRow(_ row: InventoryRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let target = row.apfsTarget {
                Toggle(row.name, isOn: Binding(
                    get: { model.inventory.protected.contains(target.id) },
                    set: { model.arbitrator.protect(target, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel("Protect \(row.name)")
                .disabled(model.inventory.busy || model.inventory.available != true)
            } else {
                Text(row.name).fontWeight(.medium)
            }
            Text(details(row)).font(.caption).foregroundStyle(.secondary)
            if row.volumes.count > 1 {
                Text(row.volumes.joined(separator: ", ")).font(.caption)
            }
            if let target = row.apfsTarget {
                if model.inventory.protected.contains(target.id) {
                    Text("Turn off protection to eject in Finder.").font(.callout)
                }
            } else {
                Text(row.reason.rawValue).font(.callout)
            }
        }
    }

    private func details(_ row: InventoryRow) -> String {
        let kind = row.apfsTarget == nil ? row.kind.rawValue : "External APFS"
        guard let bytes = row.capacity else { return kind }
        return kind + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
