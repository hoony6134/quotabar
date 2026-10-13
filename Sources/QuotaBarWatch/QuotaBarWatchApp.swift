import SwiftUI
import WidgetKit
import WatchKit

@main
struct QuotaBarWatchApp: App {
    @StateObject private var model = WatchMirrorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.reload()
                    case .background: WatchMirrorModel.scheduleBackgroundRefresh()
                    default: break
                    }
                }
        }
        // 앱이 꺼져 있어도 watchOS가 주기적으로 깨워 주는 백그라운드 갱신 —
        // iCloud 값을 당겨와 컴플리케이션을 최신으로 만든다.
        .backgroundTask(.appRefresh(WatchMirrorModel.refreshTaskID)) {
            await WatchMirrorModel.performBackgroundSync()
        }
    }
}

/// Mac이 iCloud(키-값 저장소)로 올린 스냅샷을 읽어 화면에 공급한다.
/// iPhone 앱과 같은 채널을 쓰므로 iPhone이 근처에 없어도 동작하고, 토큰은 포함되지 않는다.
@MainActor
final class WatchMirrorModel: ObservableObject {
    @Published private(set) var snapshot: WidgetSnapshot?
    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "demoMode")
            reload()
        }
    }
    @Published private(set) var isRefreshing = false

    private var observer: NSObjectProtocol?

    static let refreshTaskID = "quotabar.watch.sync"

    init() {
        demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        observer = QuotaCloudSync.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        // iPhone이 직접 밀어 주는 최신 스냅샷 — iCloud보다 빠르고 워치가 단독이어도 무해하다.
        PhoneWatchBridge.shared.onSnapshot = { snapshot in
            Task { @MainActor in Self.adopt(snapshot) }
        }
        Self.current = self
        PhoneWatchBridge.shared.activate()
        reload()
    }

    /// iPhone에서 받은 스냅샷이 현재 것보다 새로우면 앱 그룹 파일에 저장해
    /// 앱 화면과 컴플리케이션이 함께 쓰게 하고, 화면이 열려 있으면 즉시 갱신한다.
    private static var current: WatchMirrorModel?
    private static func adopt(_ snapshot: WidgetSnapshot) {
        guard snapshot.isDemo != true,
              snapshot.generatedAt > (WidgetSnapshot.load()?.generatedAt ?? .distantPast) else { return }
        snapshot.writeToGroupFiles()
        current?.reload()
        if current == nil { WidgetCenter.shared.reloadAllTimelines() }
    }

    // MARK: 백그라운드 갱신

    /// 다음 백그라운드 갱신을 예약한다 (실행 시점은 watchOS가 예산에 맞춰 정한다).
    static func scheduleBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: refreshTaskID as NSString,
            scheduledCompletion: { _ in })
    }

    /// 백그라운드에서 iCloud 값을 당겨와 컴플리케이션을 갱신하고 다음 실행을 예약한다.
    static func performBackgroundSync() async {
        scheduleBackgroundRefresh()
        PhoneWatchBridge.shared.activate()
        if let cloud = await QuotaCloudSync.pull(),
           cloud.generatedAt > (WidgetSnapshot.loadFromGroupFile()?.generatedAt ?? .distantPast) {
            cloud.writeToGroupFiles()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func reload() {
        QuotaCloudSync.synchronize()
        snapshot = demoMode ? .demo() : WidgetSnapshot.load()
        // 컴플리케이션도 새 값으로 갱신
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Mac에 갱신을 요청하고 최대 8초 동안 새 값을 기다린다.
    func requestRefresh() async {
        guard !demoMode else { reload(); return }
        isRefreshing = true
        let before = snapshot?.generatedAt
        QuotaCloudSync.requestRefresh()
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            reload()
            if let new = snapshot?.generatedAt, new != before { break }
        }
        isRefreshing = false
    }

    var hasData: Bool { !(snapshot?.items.isEmpty ?? true) }

    /// 서비스 단위로 묶은 섹션 (사용률 높은 서비스 먼저)
    var sections: [WatchServiceSection] {
        guard let snapshot else { return [] }
        var order: [String] = []
        var map: [String: [WidgetQuotaItem]] = [:]
        for item in snapshot.items {
            let key = item.serviceID ?? item.service
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(item)
        }
        return order.map { WatchServiceSection(id: $0, items: map[$0] ?? []) }
    }
}

struct WatchServiceSection: Identifiable {
    let id: String
    let items: [WidgetQuotaItem]
    var first: WidgetQuotaItem { items[0] }
    var worst: Double { items.map { $0.effectivePercent() }.max() ?? 0 }
}
