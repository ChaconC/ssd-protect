import AppKit
import ServiceManagement
import SwiftUI

struct AppSettings: View {
    @ObservedObject var model: MenuModel
    @Binding var restoresProtection: Bool
    let sessionOnlyCount: Int
    @ObservedObject var appIcons: AppIconSettings
    @StateObject var login = LoginItem()

    @State private var selection: SettingsSection = .general
    @AppStorage("hideFinderEject") private var hideFinderEject = false
    private var finderHelper: FinderRegistration { model.finderRegistration }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, id: \.self, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(ideal: 156)
        } detail: {
            Group {
                switch selection {
                case .general: general
                case .protection: protection
                case .about: AboutSettings(appIcons: appIcons)
                }
            }
            .navigationTitle(selection.rawValue)
        }
        .frame(minWidth: 630, idealWidth: 680, minHeight: 420, idealHeight: 470)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        login.refresh()
        finderHelper.refresh()
    }

    private var general: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { appIcons.choice }, set: appIcons.select)) {
                    ForEach(AppIconChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                if let error = appIcons.errorMessage { Text(error).foregroundStyle(.secondary) }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { login.status == .enabled || login.status == .requiresApproval },
                    set: login.setRequested
                )) {
                    Text("Launch at Login").frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(loginDescription).foregroundStyle(.secondary)
                if let error = login.errorMessage {
                    Text("macOS couldn’t update the login item. \(error) Check Login Items, then try again.")
                        .foregroundStyle(.secondary)
                }
                if login.status == .requiresApproval || login.status == .notFound || login.errorMessage != nil {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var protection: some View {
        Form {
            Section {
                Toggle(isOn: $restoresProtection) {
                    Text("Restore protection on launch").frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Protect your selected drives again when SSD Protect opens or the drives reconnect.")
                    .foregroundStyle(.secondary)
                if restoresProtection && sessionOnlyCount > 0 {
                    Text("\(sessionOnlyCount) session-only. These drives lack a verified, unique identity.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Hide Finder Eject on protection changes", isOn: $hideFinderEject)
                Text("Hiding Eject remounts an eligible unencrypted APFS volume. This option applies only to unencrypted volumes.").foregroundStyle(.secondary)
            }
            Section {
                Toggle("Hide Finder Eject on encrypted APFS", isOn: Binding(
                    get: { finderHelper.requested },
                    set: { enabled in
                        if enabled { finderHelper.requestApproval() }
                        else { model.disableFinderHelper(finderHelper) }
                    }
                ))
                .disabled(model.disablingFinderHelper || !model.finderRequests.isEmpty)
                if model.disablingFinderHelper {
                    ProgressView("Checking mounted volumes…").controlSize(.small)
                } else if let message = model.helperSettingsMessage, finderHelper.status == .notRegistered {
                    Text(message).foregroundStyle(.secondary)
                }
                Text("Turning this off lets you restore Finder Eject on eligible mounted volumes before removing the helper.")
                    .foregroundStyle(.secondary)
                FinderApprovalAction(registration: finderHelper)
                    .disabled(model.disablingFinderHelper || !model.finderRequests.isEmpty)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var loginDescription: String {
        switch login.status {
        case .notRegistered: return "Open SSD Protect automatically when you sign in to your Mac."
        case .enabled: return "SSD Protect will open when you sign in to your Mac."
        case .requiresApproval: return "Allow SSD Protect in Login Items to finish enabling automatic launch."
        case .notFound: return "macOS couldn’t find this login item. Open the installed copy of SSD Protect and try again."
        @unknown default: return "macOS couldn’t report the login item’s status."
        }
    }
}

private enum SettingsSection: String, CaseIterable {
    case general = "General"
    case protection = "Protection"
    case about = "About"

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .protection: "shield"
        case .about: "info.circle"
        }
    }
}

struct AboutSettings: View {
    @ObservedObject var appIcons: AppIconSettings
    var bundle = Bundle.main

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: appIcons.preview(appIcons.choice))
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text(value("CFBundleDisplayName") ?? value("CFBundleName") ?? "SSD Protect")
                .font(.title.bold())
            if let version = value("CFBundleShortVersionString"), let build = value("CFBundleVersion") {
                Text("Version \(version) (\(build))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func value(_ key: String) -> String? { bundle.object(forInfoDictionaryKey: key) as? String }
}
