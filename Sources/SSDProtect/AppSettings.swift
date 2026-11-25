import AppKit
import ServiceManagement
import SwiftUI

struct AppSettings: View {
    @Binding var restoresProtection: Bool
    let sessionOnlyCount: Int
    @StateObject var login = LoginItem()

    var body: some View {
        TabView {
            GeneralSettings(restoresProtection: $restoresProtection, sessionOnlyCount: sessionOnlyCount, login: login)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 392)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @Binding var restoresProtection: Bool
    let sessionOnlyCount: Int
    @ObservedObject var login: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
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
            Divider()
            VStack(alignment: .leading, spacing: 7) {
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
        }
        .toggleStyle(.switch)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
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

struct AboutSettings: View {
    var bundle = Bundle.main

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.bundlePath))
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
