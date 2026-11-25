import AppKit
import DriveArbitration
import SwiftUI

private final class MenuModel: ObservableObject {
    @Published var inventory = Inventory()
    lazy var arbitrator = Arbitrator { [weak self] state in self?.inventory = state }

    init() { arbitrator.start() }

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
        MenuBarExtra("SSD Protect", systemImage: "externaldrive.badge.checkmark") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SSD Protect").font(.headline)
                if model.inventory.drives.isEmpty {
                    Text("No eligible test drive mounted.").foregroundStyle(.secondary)
                }
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
                if !model.inventory.message.isEmpty {
                    Text(model.inventory.message).font(.callout)
                }
                Button("Quit and Stop Protection") { NSApp.terminate(nil) }
            }
            .padding()
            .frame(width: 310)
        }
        .menuBarExtraStyle(.window)
    }
}
