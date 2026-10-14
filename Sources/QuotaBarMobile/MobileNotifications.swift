import Foundation
import UserNotifications

/// iPhone 리셋 알림 — Mac이 올린 스냅샷의 리셋 시각(resetsAt)으로 로컬 알림을 예약한다.
/// 서버·푸시 없이 동작하며, 스냅샷이 갱신될 때마다(앱 실행·백그라운드 갱신) 다시 예약해
/// 리셋 시각이 바뀐 롤링 윈도우도 따라간다. 켜 둔 알림은 Apple Watch로도 함께 전달된다.
final class MobileNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MobileNotifications()
    static let enabledKey = "resetNotifications"
    private static let idPrefix = "reset-"
    /// iOS는 앱당 예약 알림을 64개로 제한한다.
    private static let maxPending = 60

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 앱 시작 시 한 번 호출해 앞서 실행 중에도 배너가 보이도록 델리게이트를 붙인다.
    func install() {}

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 스냅샷 기준으로 리셋 알림을 다시 예약한다. 꺼져 있거나 데모면 예약분을 지운다.
    func reschedule(for snapshot: WidgetSnapshot?) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        guard Self.isEnabled, let snapshot, snapshot.isDemo != true else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let now = Date()
        let upcoming = snapshot.items
            .filter { ($0.resetsAt ?? .distantPast) > now.addingTimeInterval(5) }
            .sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
            .prefix(Self.maxPending)

        for item in upcoming {
            guard let resetsAt = item.resetsAt else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(item.title) 한도 초기화"
            let label = item.label != "기본" ? "[\(item.label)] " : ""
            content.body = "\(label)\(item.name) 쿼터가 초기화되었습니다."
            content.sound = .default
            content.threadIdentifier = item.serviceID ?? item.service

            let interval = max(resetsAt.timeIntervalSinceNow, 1)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: Self.idPrefix + item.id, content: content, trigger: trigger))
        }
    }

    // 앱이 열려 있을 때도 배너를 보여준다.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
