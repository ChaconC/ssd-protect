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
                        self.scanMessage = rows.isEmpty ? "No drives found." : nil
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

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 10) {
                Text("SSD Protect").font(.headline)
                Text(protectionStatus).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
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
                        ForEach(readOnlyRows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).fontWeight(.medium)
                                Text(details(row)).font(.caption).foregroundStyle(.secondary)
                                if row.volumes.count > 1 {
                                    Text(row.volumes.joined(separator: ", ")).font(.caption)
                                }
                                Text(row.reason.rawValue).font(.callout)
                            }
                            Divider()
                        }
                        if let message = model.scanMessage {
                            Text(message).foregroundStyle(.secondary)
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
        } label: {
            MenuBarIcon(protectedCount: protectedCount)
                .accessibilityLabel("SSD Protect")
                .accessibilityValue(protectionStatus)
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

    private var readOnlyRows: [InventoryRow] {
        let eligible = Set(model.inventory.drives.map(\.id))
        return model.rows.filter { row in !(row.attachment.map(eligible.contains) ?? false) }
    }

    private func details(_ row: InventoryRow) -> String {
        guard let bytes = row.capacity else { return row.kind.rawValue }
        return row.kind.rawValue + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
