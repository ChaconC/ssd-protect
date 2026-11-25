import SwiftUI
import Combine
import ServiceManagement

/// Remember the requested helper across updates while leaving macOS in control of approval.
final class FinderRegistration: ObservableObject {
    enum Recovery: Equatable { case none, registerBuild, approve }

    private let key = "finderHelperRequestedBuild"
    private let defaults: UserDefaults
    private let build: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var requested = false
    @Published private(set) var recovery: Recovery = .none
    @Published private(set) var errorMessage: String?
    var ready: Bool { status == .enabled && recovery == .none }

    init(defaults: UserDefaults = .standard, build: String? = try? FinderHelper.peerRequirement(),
         status: @escaping () -> SMAppService.Status = { FinderHelper.service.status },
         register: @escaping () throws -> Void = { try FinderHelper.service.register() },
         unregister: @escaping () throws -> Void = { try FinderHelper.service.unregister() }) {
        self.defaults = defaults
        self.build = build
        self.readStatus = status
        self.register = register
        self.unregister = unregister
        self.status = status()
        refresh()
    }

    func refresh() {
        status = readStatus()
        let previous = defaults.string(forKey: key)
        let registered = status == .enabled || status == .requiresApproval
        requested = previous != nil || registered
        if !requested {
            recovery = .none
        } else if build == nil || previous != build || !registered {
            recovery = .registerBuild
        } else {
            recovery = status == .requiresApproval ? .approve : .none
        }
    }

    func setRequested(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        defer { refresh() }
        do {
            if enabled {
                guard let build else {
                    errorMessage = "SSD Protect couldn’t verify its signature. Reopen the installed app."
                    return
                }
                if ready || recovery == .approve { return }
                // Retain intent if removing a stale registration succeeds but registering fails.
                if defaults.string(forKey: key) == nil { defaults.set("pending", forKey: key) }
                if status == .enabled || status == .requiresApproval { try unregister() }
                do { try register() }
                catch {
                    guard readStatus() == .requiresApproval else { throw error }
                }
                defaults.set(build, forKey: key)
            } else {
                if status == .enabled || status == .requiresApproval { try unregister() }
                defaults.removeObject(forKey: key)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FinderApprovalAction: View {
    @ObservedObject var registration: FinderRegistration

    var body: some View {
        switch registration.recovery {
        case .registerBuild:
            Button("Register Finder Helper for This Build…") {
                registration.setRequested(true)
                if registration.recovery == .approve { SMAppService.openSystemSettingsLoginItems() }
            }
        case .approve:
            Button("Approve Finder Helper in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
        case .none:
            EmptyView()
        }
        if let message = registration.errorMessage { Text(message).foregroundStyle(.secondary) }
    }
}
