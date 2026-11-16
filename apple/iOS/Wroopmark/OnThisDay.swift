import Foundation
import UserNotifications

/// "On this day": once a day, not before nine, if something was saved on
/// this date in a past year, a notification shows it. Off until the user
/// turns it on in Settings (that is when iOS asks for permission).
enum OnThisDay {
    static let enabledKey = "onThisDayNotify"
    private static let sentKey = "onThisDaySent"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Asks for permission; false if the user said no.
    static func enable() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    static func disable() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["on-this-day"])
    }

    /// Run when the app leaves the screen and on background visits.
    static func notifyIfDue(core: Core) async {
        guard enabled else { return }
        let today = Calendar.current.startOfDay(for: .now)
        if let sent = UserDefaults.standard.object(forKey: sentKey) as? Date, sent >= today { return }
        guard let result: TodayResult = try? await core.call(.call("today", [:])), let first = result.onThisDay.first else { return }

        let content = UNMutableNotificationContent()
        // A match may be the day it was saved or the day it was posted, so
        // no "N years ago": just how many there are.
        content.title = String(localized: "Geçmişte bugün")
        if result.onThisDay.count > 1 {
            content.subtitle = String(localized: "Geçmiş yıllardan \(result.onThisDay.count) kayıt")
        }
        content.body = [first.author, first.headline].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        content.userInfo = ["open": "today"]
        content.sound = nil

        // Not before nine in the morning.
        var nine = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        nine.hour = 9
        let at = Calendar.current.date(from: nine) ?? .now
        let trigger: UNNotificationTrigger? = at > .now ? UNCalendarNotificationTrigger(dateMatching: nine, repeats: false) : nil
        let request = UNNotificationRequest(identifier: "on-this-day", content: content, trigger: trigger)
        if (try? await UNUserNotificationCenter.current().add(request)) != nil {
            UserDefaults.standard.set(Date.now, forKey: sentKey)
        }
    }
}

/// A tap on the notification opens Today.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.userInfo["open"] as? String == "today" {
            await MainActor.run { PhoneModel.pendingAction = "today" }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
