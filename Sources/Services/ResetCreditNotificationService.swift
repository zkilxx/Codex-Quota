import AppKit
import UserNotifications

@MainActor
protocol ResetCreditNotifying {
    func requestPermissionIfNeeded() async
    func notify(identifier: String, title: String, body: String) async -> Bool
}

@MainActor
final class ResetCreditNotificationService: NSObject, ResetCreditNotifying, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var beepedIDs: Set<String> = []
    var onOpen: (() -> Void)?
    var onPermissionGranted: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: "open-reset-cards", title: "查看重置卡", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "reset-credit-expiring", actions: [action], intentIdentifiers: [])])
    }

    func requestPermissionIfNeeded() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
                onPermissionGranted?()
            }
        } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            onPermissionGranted?()
        }
    }

    func notify(identifier: String, title: String, body: String) async -> Bool {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            if beepedIDs.insert(identifier).inserted { NSSound.beep() }
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "reset-credit-expiring"
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch { return false }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }
}
