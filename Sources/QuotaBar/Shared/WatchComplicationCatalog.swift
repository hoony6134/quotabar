#if os(watchOS)
import Foundation

/// "한도 선택" 컴플리케이션의 추천 목록(recommendations) 원본.
///
/// watchOS는 이 추천 목록에 없는 구성을 페이스에서 지우고, 목록을 다시 묻기 전까지는 마지막 결과를 그대로 쓴다.
/// 그래서 연결이 끊기거나 재부팅 직후처럼 스냅샷을 잠깐 못 읽을 때 빈 목록을 돌려주면
/// 올려 둔 컴플리케이션이 사라지고, 재연결돼도 목록이 비어 기본 컴플리케이션만 남는다.
/// - 익스텐션: 마지막으로 보여준 목록을 저장해 두고, 스냅샷이 비면 그것을 그대로 돌려준다.
/// - 앱: 스냅샷이 있고 익스텐션이 마지막으로 보여준 목록과 달라졌을 때만 추천을 다시 만들게 한다.
enum WatchComplicationCatalog {
    struct Entry: Codable, Equatable {
        var id: String
        var label: String
    }

    static let maxEntries = 12
    private static let servedKey = "watch.recommendations.served.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: QuotaWidgetShared.appGroupID)
    }

    /// 스냅샷 항목으로 만든 추천 목록 (비어 있으면 빈 배열)
    static func entries(from items: [WidgetQuotaItem]) -> [Entry] {
        items.prefix(maxEntries).map { Entry(id: $0.id, label: "\($0.title) · \($0.name)") }
    }

    /// 익스텐션이 마지막으로 돌려준 목록
    static var served: [Entry] {
        guard let data = defaults?.data(forKey: servedKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    /// 익스텐션용: 지금 돌려줄 목록. 현재 스냅샷이 비면 마지막 목록을 유지하고, 있으면 그것을 기록한다.
    static func resolve(current items: [WidgetQuotaItem]) -> [Entry] {
        let current = entries(from: items)
        guard !current.isEmpty else { return served }
        if current != served, let data = try? JSONEncoder().encode(current) {
            defaults?.set(data, forKey: servedKey)
        }
        return current
    }

    /// 앱용: 추천 목록을 다시 만들어야 하는지 (빈 스냅샷으로는 절대 다시 만들지 않는다)
    static func needsInvalidation(for items: [WidgetQuotaItem]) -> Bool {
        let current = entries(from: items)
        return !current.isEmpty && current != served
    }
}
#endif
