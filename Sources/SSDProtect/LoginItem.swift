import Combine
import ServiceManagement

final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let readStatus: () -> SMAppService.Status
    private let change: (Bool) throws -> Void

    init(status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         change: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.readStatus = status
        self.change = change
        self.status = status()
    }

    func refresh() {
        let current = readStatus()
        if current != status { errorMessage = nil }
        status = current
    }

    func setRequested(_ enabled: Bool) {
        errorMessage = nil
        do {
            try change(enabled)
            refresh()
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }
}
