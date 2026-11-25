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
    lazy var arbitrator = Arbitrator(restorationDefaults: .standard, topologyChanged: { [weak self] in self?.refresh() }) { [weak self] state in
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

    func changeProtection(_ target: APFSProtectionTarget, enabled: Bool) {
        guard let volume = target.finderVolume,
              UserDefaults.standard.bool(forKey: "hideFinderEject") || (!enabled && target.hasFinderMountFlag) else {
            arbitrator.protect(target, enabled: enabled)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remount \(volume.lastPathComponent)?"
        alert.informativeText = "Save your work and close files on \(volume.lastPathComponent). SSD Protect will briefly unmount this volume to change Finder’s Eject control."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: enabled ? "Remount and Protect" : "Remount and Unprotect").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { arbitrator.changeFinderProtection(target, enabled: enabled) }
    }

    func confirm(_ drive: Drive) {
        let alert = NSAlert()
        alert.messageText = "Eject \(drive.name)?"
        alert.informativeText = "Save your work and stop transfers on \(drive.name) before ejecting this drive."
        if confirmsEject(alert) { arbitrator.ejectConfirmed(drive) }
    }

    func confirm(_ target: APFSProtectionTarget, named name: String) {
        let alert = NSAlert()
        alert.messageText = "Eject the entire drive containing \(name)?"
        let paths = target.mountedVolumes.values.map(\.path).sorted()
        if paths.isEmpty {
            alert.messageText = "Eject \(name)?"
            alert.informativeText = "This will eject the entire drive. No volumes are currently mounted."
        } else {
            alert.informativeText = "Save your work and stop transfers. Ejecting this drive will unmount every volume listed below."
            if paths.joined(separator: "\n").count < 240 && paths.count <= 4 {
                alert.informativeText += "\n\n" + paths.joined(separator: "\n")
            } else {
                alert.accessoryView = scrollablePaths(paths)
            }
        }
        if confirmsEject(alert) { arbitrator.ejectConfirmed(target) }
    }

    private func scrollablePaths(_ paths: [String]) -> NSView {
        let list = NSHostingView(rootView: ScrollView {
            Text(verbatim: paths.joined(separator: "\n"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280))
        list.setFrameSize(list.fittingSize)
        return list
    }

    private func confirmsEject(_ alert: NSAlert) -> Bool {
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Eject").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@main
struct SSDProtectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = MenuModel()
    var body: some Scene {
        MenuBarExtra {
            DriveMenu(model: model, requestQuit: delegate.requestQuit)
        } label: {
            MenuBarIcon(protectedCount: protectedCount)
                .accessibilityLabel("SSD Protect")
                .accessibilityValue(model.inventory.menuBarStatus)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettings(restoresProtection: Binding(
                get: { model.inventory.restoresProtection },
                set: model.arbitrator.setRestoresProtection
            ), sessionOnlyCount: model.inventory.sessionOnly.count, appIcons: delegate.appIcons)
        }
        .windowResizability(.contentSize)
    }

    private var protectedCount: Int {
        model.inventory.protected.count
    }
}

extension Inventory {
    var protectionWarning: String? {
        guard let available else { return "Starting protection…" }
        guard available else { return "Protection unavailable" }
        let suspended = suspendedAPFS.count
        return suspended == 0 ? nil : "Protection suspended for \(suspended) \(suspended == 1 ? "drive" : "drives")"
    }

    var menuBarStatus: String {
        guard available == true, !protected.isEmpty else {
            return protectionWarning ?? "No drives protected"
        }
        let active = "Protecting \(protected.count) \(protected.count == 1 ? "drive" : "drives")"
        return suspendedAPFS.isEmpty ? active : "\(active) · \(suspendedAPFS.count) suspended"
    }
}

private struct DriveMenu: View {
    @ObservedObject var model: MenuModel
    let requestQuit: (NSWindow) -> Void
    @StateObject private var option = OptionKey()
    @State private var showsSimulatorImages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSD Protect").font(.headline)
            if let warning = model.inventory.protectionWarning {
                Text(warning).foregroundStyle(.secondary)
            }
            Divider()
            ViewThatFits(in: .vertical) {
                driveList.fixedSize(horizontal: false, vertical: true)
                ScrollView { driveList }.frame(height: 370)
            }
            .frame(maxHeight: 370)
            .fixedSize(horizontal: false, vertical: true)
            if !model.inventory.message.isEmpty {
                Text(model.inventory.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings")
                .help("Open Settings")
                Spacer()
                QuitButton(request: requestQuit).fixedSize()
            }
        }
        .padding()
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in MenuWindowSizing(height: geometry.size.height) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            option.start()
            model.refresh()
        }
        .onDisappear { option.stop() }
    }

    private var driveList: some View {
        VStack(alignment: .leading, spacing: 10) {
            let rows = inventoryRows
            let simulators = rows.filter { $0.kind == .simulatorImage }
            ForEach(model.inventory.drives) { drive in
                DriveRow(icon: drive.icon, name: drive.name) {
                    Text(drive.transport)
                    restorationNote(for: drive.id)
                } actions: {
                    DriveActions(name: drive.name, protected: Binding(
                        get: { model.inventory.protected.contains(drive.id) },
                        set: { model.arbitrator.protect(drive, enabled: $0) }
                    ), optionDown: option.isDown, eject: { model.confirm(drive) },
                       forceEject: { model.arbitrator.forceEject(drive) })
                }.disabled(controlsUnavailable)
            }
            ForEach(rows.filter { $0.kind != .simulatorImage }) { row in
                inventoryRow(row)
            }
            if !simulators.isEmpty {
                Button {
                    showsSimulatorImages.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsSimulatorImages ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .frame(width: 12)
                        Text("Simulator disk images (\(simulators.count))")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsSimulatorImages ? "Expanded" : "Collapsed")
                if showsSimulatorImages {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(simulators) { row in inventoryRow(row) }
                    }
                    .padding(.leading, 17)
                }
            }
            if let message = model.scanMessage {
                Text(message).foregroundStyle(.secondary)
            } else if rows.isEmpty && model.inventory.drives.isEmpty {
                Text("No drives to show.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsUnavailable: Bool { model.inventory.busy || model.inventory.available != true }

    private var inventoryRows: [InventoryRow] {
        let eligible = Set(model.inventory.drives.map(\.id))
        return model.rows.filter { row in
            row.reason != .startup && !(row.attachment.map(eligible.contains) ?? false)
        }
    }

    private func inventoryRow(_ row: InventoryRow) -> some View {
        let suspended = row.attachment.flatMap { model.inventory.suspendedAPFS.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 4) {
            DriveRow(icon: row.icon, name: row.name) {
                Text(details(row))
                if let id = row.attachment { restorationNote(for: id) }
                if row.volumes.count > 1 { Text(row.volumes.joined(separator: ", ")) }
                if row.apfsTarget?.mountedVolumes.isEmpty == true {
                    Text("Unmounted")
                } else if suspended != nil {
                    Text("Protection suspended until the drive can be verified.")
                } else if row.apfsTarget == nil {
                    Text(row.reason.rawValue)
                }
            } actions: {
                if let target = row.apfsTarget, target.mountedVolumes.isEmpty {
                    if target.canRemount {
                        Button("Mount") { model.arbitrator.remount(target, named: row.name) }
                            .accessibilityLabel("Mount \(row.name)")
                            .disabled(controlsUnavailable)
                    } else {
                        Button("Eject…") { model.confirm(target, named: row.name) }.disabled(controlsUnavailable)
                    }
                } else if let target = row.apfsTarget, suspended == nil {
                    DriveActions(name: row.name, protected: Binding(
                        get: { model.inventory.protected.contains(target.id) },
                        set: { model.changeProtection(target, enabled: $0) }
                    ), optionDown: option.isDown, eject: { model.confirm(target, named: row.name) },
                       forceEject: { model.arbitrator.forceEject(target) })
                        .disabled(controlsUnavailable)
                }
            }
            if let suspended {
                Button("Turn Off Protection") { model.arbitrator.disableAPFSProtection(for: suspended) }
                    .disabled(controlsUnavailable)
            }
        }
    }

    @ViewBuilder private func restorationNote(for id: UInt64) -> some View {
        if model.inventory.restoresProtection && model.inventory.sessionOnly.contains(id) {
            Text("Session only. Drive identity couldn’t be verified for restoration.")
        }
    }

    private func details(_ row: InventoryRow) -> String {
        let kind = row.apfsTarget == nil ? row.kind.rawValue : "External APFS"
        guard let bytes = row.capacity else { return kind }
        return kind + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
