import DriveArbitration
import UserNotifications

final class ProtectionNotifications: NSObject, UNUserNotificationCenterDelegate {
    func post(_ notice: ProtectionNotice) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            case .authorized, .provisional:
                break
            default:
                return
            }
            let content = UNMutableNotificationContent()
            switch notice {
            case let .changed(name, enabled):
                content.title = enabled ? "Protection enabled" : "Protection disabled"
                content.body = name
            case let .restored(names):
                content.title = "Protection restored"
                content.body = names.joined(separator: ", ")
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
