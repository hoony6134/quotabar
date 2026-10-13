import SwiftUI
import WidgetKit

@main
struct QuotaBarWatchApp: App {
    @StateObject private var model = WatchMirrorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.reload() }
                }
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

    init() {
        demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        observer = QuotaCloudSync.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        QuotaCloudSync.synchronize()
        snapshot = demoMode ? .demo() : WidgetSnapshot.load()
        // 컴플리케이션도 새 값으로 갱신
        WidgetCenter.shared.reloadAllTimelines()
        // 컴플리케이션 목록의 "한도 선택" 항목도 새 쿼터 목록으로 다시 만든다
        WidgetCenter.shared.invalidateConfigurationRecommendations()
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
