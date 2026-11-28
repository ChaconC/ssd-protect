import AppKit
import Combine
import DriveArbitration
import SwiftUI

final class MenuModel: ObservableObject {
    let finderRegistration = FinderRegistration()
    @Published var inventory = Inventory()
    @Published var rows: [InventoryRow] = []
    @Published var scanMessage: String? = "Reading drive inventory…"
    @Published private(set) var finderFlags: [UInt64: Bool] = [:]
    @Published private(set) var finderRequests: [UInt64: UUID] = [:]
    @Published var finderUpdateMessage: String?
    @Published var offersFinderRelaunch = false
    @Published private(set) var disablingFinderHelper = false
    @Published private(set) var helperSettingsMessage: String?
    private let scanner = DispatchQueue(label: "SSDProtect.Inventory", qos: .utility)
    private var revision = 0
    @Published private(set) var scanning = false
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
        finderRegistration.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
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
            self.finderRegistration.refresh()
            let readFlags = self.finderRegistration.ready
            self.scanner.async {
                let result = Result {
                    let rows = try DriveInventory.read()
                    var flags: [UInt64: Bool] = [:]
                    if readFlags {
                        for target in rows.compactMap(\.apfsTarget) {
                            flags[target.id] = target.encryptedFinderFlag
                        }
                    }
                    return (rows, flags)
                }
                DispatchQueue.main.async {
                    self.scanning = false
                    guard self.revision == requested else { self.refresh(); return }
                    switch result {
                    case .success(let (rows, flags)):
                        self.finderFlags = flags
                        self.rows = rows
                        self.scanMessage = nil
                    case .failure:
                        self.finderFlags = [:]
                        self.rows = []
                        self.scanMessage = "Drive inventory unavailable."
                    }
                }
            }
        }
    }

    func changeProtection(_ target: APFSProtectionTarget, enabled: Bool) {
        finderUpdateMessage = nil
        finderRegistration.refresh()
        if !disablingFinderHelper, finderRegistration.ready, target.encryptedIdentity != nil {
            guard let request = beginFinderUpdate(target) else { return }
            arbitrator.protect(target, enabled: enabled) { [weak self] applied in
                guard let self, self.finderRequests[target.id] == request else { return }
                if applied {
                    self.performFinderUpdate(target, set: enabled, request: request)
                } else {
                    self.finderRequests[target.id] = nil
                }
            }
            return
        }
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

    func updateFinderFlag(_ target: APFSProtectionTarget, set: Bool) {
        guard let request = beginFinderUpdate(target) else { return }
        performFinderUpdate(target, set: set, request: request)
    }

    private func beginFinderUpdate(_ target: APFSProtectionTarget) -> UUID? {
        guard !disablingFinderHelper, finderRequests[target.id] == nil, !inventory.busy else { return nil }
        let request = UUID()
        finderRequests[target.id] = request
        finderUpdateMessage = nil
        // Enrollment and service discovery happen before the XPC reply deadline starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard self.finderRequests[target.id] == request else { return }
            self.finderRequests[target.id] = nil
            self.finderUpdateMessage = "Finder update timed out. The mount state is unverified."
            self.refresh()
        }
        return request
    }

    private func performFinderUpdate(_ target: APFSProtectionTarget, set: Bool, request: UUID) {
        guard let path = target.encryptedFinderVolume else { finderRequests[target.id] = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try FinderHelper.request(target, set: set) }
            DispatchQueue.main.async {
                guard self.finderRequests[target.id] == request else { return }
                self.finderRequests[target.id] = nil
                switch result {
                case .success:
                    self.offersFinderRelaunch = true
                    self.finderUpdateMessage = "Finder flag verified \(set ? "on" : "off") for \(path.lastPathComponent). Relaunch Finder to refresh its Eject controls."
                case .failure(let error):
                    self.finderUpdateMessage = "Finder update failed for \(path.lastPathComponent). \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    func disableFinderHelper(_ registration: FinderRegistration) {
        guard !disablingFinderHelper, finderRequests.isEmpty else { return }
        helperSettingsMessage = nil
        guard registration.ready else {
            let alert = NSAlert()
            alert.messageText = "Disable the Finder helper?"
            alert.informativeText = "The helper is unavailable. Existing Finder mount flags will stay set until you restore them with an approved helper."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Disable Only")
            if alert.runModal() == .alertSecondButtonReturn {
                registration.setRequested(false)
                refresh()
            }
            return
        }
        disablingFinderHelper = true
        FinderDisableScan.start { scan in
            switch scan {
            case .failure(let error):
                self.finishFinderDisable(registration, error: error)
            case .success(let targets):
                guard !targets.isEmpty else {
                    self.finishFinderDisable(registration, error: nil)
                    return
                }
                // A volume may already have carried this flag before SSD Protect ran.
                // Name every affected mount and let the user decline the changes.
                let alert = NSAlert()
                alert.messageText = "Restore Finder Eject before disabling the helper?"
                alert.informativeText = targets.compactMap { $0.encryptedFinderVolume?.path }.sorted().joined(separator: "\n")
                    + "\n\nThese mounted encrypted volumes have the Finder flag set. Ordinary protection stays active."
                alert.addButton(withTitle: "Restore and Disable")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Disable Only")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    self.restoreBeforeDisabling(targets, registration: registration)
                case .alertThirdButtonReturn:
                    self.finishFinderDisable(registration, error: nil)
                default:
                    self.disablingFinderHelper = false
                }
            }
        }
    }

    private func restoreBeforeDisabling(_ targets: [APFSProtectionTarget], registration: FinderRegistration) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                for target in targets { try FinderHelper.request(target, set: false) }
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.offersFinderRelaunch = true
                    self.finderUpdateMessage = "Finder mount flags cleared. Relaunch Finder to refresh its Eject controls."
                    self.finishFinderDisable(registration, error: nil)
                case .failure(let error):
                    self.finishFinderDisable(registration, error: error)
                }
            }
        }
    }

    private func finishFinderDisable(_ registration: FinderRegistration, error: Error?) {
        disablingFinderHelper = false
        if let error {
            let alert = NSAlert()
            alert.messageText = "Couldn’t verify Finder Eject on every volume."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Keep Helper Enabled")
            alert.addButton(withTitle: "Disable Only")
            if alert.runModal() == .alertSecondButtonReturn { registration.setRequested(false) }
        } else {
            registration.setRequested(false)
            if offersFinderRelaunch { helperSettingsMessage = "Relaunch Finder from the SSD Protect menu to refresh its Eject controls." }
        }
        refresh()
    }

    func confirmFinderRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Relaunch Finder?"
        alert.informativeText = "Finish any copies or moves in Finder first. Relaunching interrupts Finder operations and refreshes Eject controls for all volumes."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Relaunch Finder").keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let finders = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        let systemFinder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app").standardizedFileURL
        guard let finder = finders.first(where: { $0.bundleURL?.standardizedFileURL == systemFinder }),
              !finder.isTerminated, finder.processIdentifier > 0,
              Darwin.kill(finder.processIdentifier, SIGTERM) == 0 else {
            finderUpdateMessage = "Couldn’t relaunch Finder. Use Relaunch in Finder’s Dock menu."
            return
        }
        offersFinderRelaunch = false
        finderUpdateMessage = "Finder relaunch requested."
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
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--finder-mount-helper"]) {
            do { try FinderHelper.serve() } catch { exit(EXIT_FAILURE) }
        }
        SSDProtectApp.main()
    }
}

struct SSDProtectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings {
            ProtectionSettings(model: delegate.model, appIcons: delegate.appIcons)
        }
        .windowResizability(.contentSize)
    }
}

private struct ProtectionSettings: View {
    @ObservedObject var model: MenuModel
    let appIcons: AppIconSettings

    var body: some View {
        AppSettings(model: model, restoresProtection: Binding(
            get: { model.inventory.restoresProtection },
            set: model.arbitrator.setRestoresProtection
        ), sessionOnlyCount: model.inventory.sessionOnly.count, appIcons: appIcons)
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

struct DriveMenu: View {
    @ObservedObject var model: MenuModel
    let requestQuit: (NSWindow) -> Void
    let availableHeight: CGFloat
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings
    @StateObject private var option = OptionKey()
    private var hideEncryptedFinderEject: Bool { model.finderRegistration.ready }
    @State private var showsSimulatorImages = false

    var body: some View {
        DriveMenuLayout(availableHeight: availableHeight) {
            Text("SSD Protect").font(.headline)
            if let warning = model.inventory.protectionWarning {
                Text(warning).foregroundStyle(.secondary)
            }
        } rows: {
            driveList
        } footer: {
            FinderApprovalAction(registration: model.finderRegistration)
                .disabled(model.disablingFinderHelper || !model.finderRequests.isEmpty)
            if let message = model.finderUpdateMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if model.offersFinderRelaunch {
                Button("Relaunch Finder…", action: model.confirmFinderRelaunch)
                    .disabled(!model.finderRequests.isEmpty)
            }
            if !model.inventory.message.isEmpty {
                Text(model.inventory.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button {
                    // A status item can receive the press while another app owns keyboard focus.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                    dismiss()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Settings")
                .help("Open Settings")
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh drive list")
                .help("Refresh drive list")
                .disabled(model.scanning)
                Spacer()
                QuitButton(request: requestQuit).fixedSize()
            }
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
        let controlsUnavailable = self.controlsUnavailable || row.attachment.flatMap { model.finderRequests[$0] } != nil
        let suspended = row.attachment.flatMap { model.inventory.suspendedAPFS.contains($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 4) {
            DriveRow(icon: row.icon, name: row.name) {
                Text(details(row))
                if let id = row.attachment { restorationNote(for: id) }
                if row.volumes.count > 1 { Text(row.volumes.joined(separator: ", ")) }
                if row.apfsTarget?.mountedVolumes.isEmpty == true {
                    Text(row.apfsTarget?.singleVolumeLocked == true ? "Locked" : "Connected · Unmounted")
                } else if suspended != nil {
                    Text("Protection suspended until the drive can be verified.")
                } else if row.apfsTarget == nil {
                    Text(row.reason.rawValue)
                }
            } actions: {
                if let target = row.apfsTarget, target.mountedVolumes.isEmpty {
                    if target.canRemount || target.singleVolumeLocked {
                        Button {
                            model.arbitrator.remount(target, named: row.name)
                        } label: {
                            if target.singleVolumeLocked { Label("Unlock", systemImage: "lock.fill") }
                            else { Text("Mount") }
                        }
                            .accessibilityLabel(target.singleVolumeLocked ? "Unlock \(row.name)" : "Mount \(row.name)")
                            .disabled(controlsUnavailable)
                    }
                    Button { model.confirm(target, named: row.name) } label: {
                        Image(systemName: "eject").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Eject \(row.name)")
                    .help("Eject the connected drive \(row.name)…")
                    .disabled(controlsUnavailable)
                } else if let target = row.apfsTarget, let staging = model.inventory.finderRecoveryPaths[target.id],
                          target.mountedVolumes.values.contains(staging) {
                    Button("Retry Remount") { model.arbitrator.retryFinderRemount(target) }
                        .disabled(controlsUnavailable)
                        .help("Restore the volume mounted at \(staging.path) after closing its open files.")
                } else if let target = row.apfsTarget, suspended == nil {
                    DriveActions(name: row.name, protected: Binding(
                        get: { model.inventory.protected.contains(target.id) },
                        set: { model.changeProtection(target, enabled: $0) }
                    ), optionDown: option.isDown, eject: { model.confirm(target, named: row.name) },
                       forceEject: { model.arbitrator.forceEject(target) })
                        .disabled(controlsUnavailable)
                }
            }
            if !model.disablingFinderHelper, hideEncryptedFinderEject, let target = row.apfsTarget, let set = model.finderFlags[target.id],
               model.inventory.protected.contains(target.id) != set {
                Button("Retry Finder Update") {
                    model.updateFinderFlag(target, set: !set)
                }
                .disabled(controlsUnavailable)
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
