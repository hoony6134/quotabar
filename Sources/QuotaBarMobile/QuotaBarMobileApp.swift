import SwiftUI
import WidgetKit
import BackgroundTasks

@main
struct QuotaBarMobileApp: App {
    @StateObject private var model = MirrorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(nil)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.reload()
                    case .background: MirrorModel.scheduleBackgroundRefresh()
                    default: break
                    }
                }
        }
        // 앱을 열지 않아도 iOS가 틈틈이 깨워 주는 백그라운드 갱신:
        // iCloud 값을 당겨와 위젯을 갱신하고 워치로 밀어 준다.
        .backgroundTask(.appRefresh(MirrorModel.refreshTaskID)) {
            await MirrorModel.performBackgroundSync()
        }
    }
}

/// Mac이 iCloud로 올린 스냅샷을 읽어 화면과 위젯에 공급한다.
@MainActor
final class MirrorModel: ObservableObject {
    @Published private(set) var snapshot: WidgetSnapshot?
    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "demoMode")
            reload()
        }
    }
    @Published private(set) var isRefreshing = false
    /// 리셋 알림 (기본 꺼짐). 켜면 권한을 요청하고 스냅샷의 리셋 시각으로 예약한다.
    @Published var resetNotifications: Bool {
        didSet {
            UserDefaults.standard.set(resetNotifications, forKey: MobileNotifications.enabledKey)
            Task { @MainActor in
                if resetNotifications, await !MobileNotifications.shared.requestAuthorization() {
                    resetNotifications = false
                    return
                }
                await MobileNotifications.shared.reschedule(for: snapshot)
            }
        }
    }

    private var observer: NSObjectProtocol?

    static let refreshTaskID = "com.wevoid.quotabar.refresh"

    init() {
        demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        resetNotifications = MobileNotifications.isEnabled
        MobileNotifications.shared.install()
        observer = QuotaCloudSync.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        PhoneWatchBridge.shared.activate()
        reload()
    }

    /// iCloud(KVS)와 앱 그룹 파일 중 최신 스냅샷을 불러오고 위젯을 갱신한다.
    /// 새 값이면 Apple Watch에도 바로 전달한다.
    func reload() {
        QuotaCloudSync.synchronize()
        if demoMode {
            snapshot = .demo()
        } else {
            snapshot = WidgetSnapshot.load()
            if let snapshot {
                snapshot.writeToGroupFiles()
                PhoneWatchBridge.shared.push(snapshot)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        let current = snapshot
        Task { await MobileNotifications.shared.reschedule(for: current) }
    }

    // MARK: 백그라운드 갱신

    /// 다음 백그라운드 갱신을 예약한다 (iOS가 실제 실행 시점을 정하므로 최소 간격일 뿐이다).
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// 백그라운드에서 iCloud 값을 당겨와 위젯·워치를 갱신하고 다음 실행을 예약한다.
    static func performBackgroundSync() async {
        scheduleBackgroundRefresh()
        PhoneWatchBridge.shared.activate()
        guard UserDefaults.standard.bool(forKey: "demoMode") == false,
              let snapshot = await QuotaCloudSync.pull() else { return }
        snapshot.writeToGroupFiles()
        PhoneWatchBridge.shared.push(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        await MobileNotifications.shared.reschedule(for: snapshot)
    }

    /// 당겨서 새로고침: Mac에 갱신을 요청하고 잠시 뒤 미러 값을 다시 읽는다.
    func pullRefresh() async {
        guard !demoMode else { reload(); return }
        isRefreshing = true
        let before = snapshot?.generatedAt
        QuotaCloudSync.requestRefresh()
        // Mac이 응답하면 observeChanges가 reload()를 호출한다. 최대 8초 기다린다.
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            reload()
            if let new = snapshot?.generatedAt, new != before { break }
        }
        isRefreshing = false
    }

    var hasData: Bool { !(snapshot?.items.isEmpty ?? true) }

    /// 계정 단위로 묶은 섹션 (사용률 높은 계정 먼저) — 같은 서비스의 여러 계정은 따로 보인다
    var sections: [ServiceSection] {
        guard let snapshot else { return [] }
        var order: [String] = []
        var map: [String: [WidgetQuotaItem]] = [:]
        for item in snapshot.items {
            let key = item.accountID
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(item)
        }
        return order.map { ServiceSection(id: $0, items: map[$0] ?? []) }
    }
}

struct ServiceSection: Identifiable {
    let id: String
    let items: [WidgetQuotaItem]
    var first: WidgetQuotaItem { items[0] }
    var worst: Double { items.map { $0.effectivePercent() }.max() ?? 0 }
}
