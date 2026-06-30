import Foundation
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }
    
    func scheduleNotifications(for accounts: [Account]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        
        let now = Date()
        
        for account in accounts {
            for quota in account.quotas {
                // 이미 초기화 시간이 지났거나 없는 경우는 제외
                guard let resetsAt = quota.resetsAt, resetsAt > now else { continue }
                
                let content = UNMutableNotificationContent()
                content.title = "\(account.service.displayName) 세션 초기화"
                
                // Account 라벨이 "기본"이 아니면 포함
                let subtitle = account.label != "기본" ? "[\(account.label)] " : ""
                content.body = "\(subtitle)\(quota.def.name) 쿼터가 초기화되었습니다."
                content.sound = .default
                
                // 해당 시간에 정확히 알림
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: resetsAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                
                let request = UNNotificationRequest(identifier: "reset-\(account.id.uuidString)-\(quota.def.key)", content: content, trigger: trigger)
                
                center.add(request) { error in
                    if let error = error {
                        print("Failed to schedule notification: \(error)")
                    }
                }
            }
        }
    }
    
    func removeAllPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    // 앱이 실행 중일 때도 알림을 표시하도록 설정
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
