import SwiftUI
import WidgetKit

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
                    if phase == .active { model.reload() }
                }
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

    private var observer: NSObjectProtocol?

    init() {
        demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        observer = QuotaCloudSync.observeChanges { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    /// iCloud(KVS)와 앱 그룹 파일 중 최신 스냅샷을 불러오고 위젯을 갱신한다.
    func reload() {
        QuotaCloudSync.synchronize()
        if demoMode {
            snapshot = .demo()
        } else {
            snapshot = WidgetSnapshot.load()
            if let snapshot { snapshot.writeToGroupFiles() }
        }
        WidgetCenter.shared.reloadAllTimelines()
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

    /// 서비스 단위로 묶은 섹션 (사용률 높은 서비스 먼저)
    var sections: [ServiceSection] {
        guard let snapshot else { return [] }
        var order: [String] = []
        var map: [String: [WidgetQuotaItem]] = [:]
        for item in snapshot.items {
            let key = item.serviceID ?? item.service
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
