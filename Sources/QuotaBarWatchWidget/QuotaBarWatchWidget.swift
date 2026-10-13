import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 구성 (표시할 쿼터 선택)

/// 컴플리케이션 편집 UI에 나오는 쿼터 항목. id = "<accountID>::<quotaKey>" (스냅샷과 동일)
struct WatchQuotaItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "쿼터"
    static var defaultQuery = WatchQuotaItemQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct WatchQuotaItemQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchQuotaItemEntity] {
        let all = Self.allEntities()
        // 스냅샷에 아직 없는 항목도 선택값은 보존한다
        return identifiers.map { id in
            all.first { $0.id == id }
                ?? WatchQuotaItemEntity(id: id, title: "알 수 없는 쿼터", subtitle: "")
        }
    }

    func suggestedEntities() async throws -> [WatchQuotaItemEntity] {
        Self.allEntities()
    }

    static func allEntities() -> [WatchQuotaItemEntity] {
        (WidgetSnapshot.load()?.items ?? []).map {
            WatchQuotaItemEntity(id: $0.id, title: "\($0.service) · \($0.name)", subtitle: $0.label)
        }
    }
}

struct WatchQuotaConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "QuotaBar 설정"
    static var description = IntentDescription("컴플리케이션에 표시할 쿼터를 선택합니다. 여러 개를 고르면 번갈아 보여주고, 비워두면 사용률이 가장 높은 항목을 보여줍니다.")

    @Parameter(title: "표시할 쿼터")
    var items: [WatchQuotaItemEntity]?
}

// MARK: - 타임라인

struct WatchQuotaEntry: TimelineEntry {
    let date: Date
    /// 이 시점에 표시할 쿼터 (nil이면 아직 iCloud 미러를 받지 못한 상태)
    let item: WidgetQuotaItem?
}

struct WatchQuotaProvider: AppIntentTimelineProvider {
    /// 여러 개를 골랐을 때 다음 항목으로 넘어가는 간격
    static let rotationInterval: TimeInterval = 5 * 60
    /// 한 번에 만들어 두는 타임라인 길이
    static let horizon: TimeInterval = 90 * 60

    func placeholder(in context: Context) -> WatchQuotaEntry {
        WatchQuotaEntry(date: Date(), item: WidgetSnapshot.sample.items.first)
    }

    func snapshot(for configuration: WatchQuotaConfigIntent, in context: Context) async -> WatchQuotaEntry {
        if context.isPreview {
            return WatchQuotaEntry(date: Date(), item: WidgetSnapshot.sample.items.first)
        }
        let now = Date()
        let pool = WidgetSnapshot.load() ?? .sample
        return WatchQuotaEntry(date: now, item: Self.item(at: now, pool: pool.items, picked: Self.picked(pool, configuration)))
    }

    func timeline(for configuration: WatchQuotaConfigIntent, in context: Context) async -> Timeline<WatchQuotaEntry> {
        let now = Date()
        guard let snapshot = WidgetSnapshot.load(), !snapshot.items.isEmpty else {
            return Timeline(entries: [WatchQuotaEntry(date: now, item: nil)],
                            policy: .after(now.addingTimeInterval(15 * 60)))
        }
        let picked = Self.picked(snapshot, configuration)
        let end = now.addingTimeInterval(Self.horizon)

        var dates: Set<Date> = [now]
        // 여러 개를 골랐으면 일정 간격으로 다음 항목으로 넘어간다.
        if picked.count > 1 {
            let step = Self.rotationInterval
            var t = (floor(now.timeIntervalSince1970 / step) + 1) * step
            while t < end.timeIntervalSince1970 {
                dates.insert(Date(timeIntervalSince1970: t))
                t += step
            }
        }
        // 리셋 시각이 지나는 순간 0%로 바뀌도록 가까운 리셋 시각마다 엔트리를 추가한다.
        let pool = picked.isEmpty ? snapshot.items : picked
        for reset in pool.compactMap(\.resetsAt) where reset > now && reset < end {
            dates.insert(reset.addingTimeInterval(1))
        }

        let entries = dates.sorted().map {
            WatchQuotaEntry(date: $0, item: Self.item(at: $0, pool: snapshot.items, picked: picked))
        }
        // 워치 위젯은 갱신 예산이 작으므로 30분 간격으로 다시 읽는다.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }

    /// watchOS는 설정 가능한 위젯을 이 추천 목록으로만 컴플리케이션 목록에 보여준다.
    /// 목록이 비면 위젯 자체가 사라지므로(예: iCloud 데이터를 아직 못 읽은 때) 기본 구성을 항상 맨 앞에 둔다.
    func recommendations() -> [AppIntentRecommendation<WatchQuotaConfigIntent>] {
        var result = [AppIntentRecommendation(intent: WatchQuotaConfigIntent(),
                                              description: "가장 높은 사용률")]
        for entity in WatchQuotaItemQuery.allEntities().prefix(10) {
            var intent = WatchQuotaConfigIntent()
            intent.items = [entity]
            result.append(AppIntentRecommendation(intent: intent, description: "\(entity.title)"))
        }
        return result
    }

    /// 사용자가 고른 항목을 고른 순서대로 (스냅샷에 있는 것만). 선택이 없으면 빈 배열.
    private static func picked(_ snapshot: WidgetSnapshot, _ configuration: WatchQuotaConfigIntent) -> [WidgetQuotaItem] {
        guard let selected = configuration.items, !selected.isEmpty else { return [] }
        let byID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { byID[$0.id] }
    }

    /// 해당 시각에 보여줄 항목. 절대 시각 기준 슬롯으로 고르므로 다시 로드돼도 순서가 안정적이다.
    private static func item(at date: Date, pool: [WidgetQuotaItem], picked: [WidgetQuotaItem]) -> WidgetQuotaItem? {
        switch picked.count {
        case 0: return pool.max { $0.effectivePercent(at: date) < $1.effectivePercent(at: date) }
        case 1: return picked[0]
        default:
            let slot = Int(date.timeIntervalSince1970 / rotationInterval)
            return picked[slot % picked.count]
        }
    }
}

// MARK: - 위젯 정의

@main
struct QuotaBarWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaBarWatchComplication()
    }
}

struct QuotaBarWatchComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarWatchComplication",
                               intent: WatchQuotaConfigIntent.self,
                               provider: WatchQuotaProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuotaBar")
        .description("선택한 AI 구독 한도를 보여줍니다. 여러 개를 고르면 번갈아 표시합니다.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - 뷰

/// 서비스 로고 (없으면 SF Symbol). 컴플리케이션 틴트를 따르도록 템플릿으로 그린다.
private struct LogoMark: View {
    let serviceID: String?

    var body: some View {
        Group {
            if let logo = SharedLogo.image(for: serviceID) {
                Image(platformImage: logo)
                    .resizable()
                    .renderingMode(.template)
            } else {
                Image(systemName: SharedLogo.symbol(for: serviceID))
                    .resizable()
            }
        }
        .scaledToFit()
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchQuotaEntry

    var body: some View {
        if let item = entry.item {
            let percent = item.effectivePercent(at: entry.date)
            switch family {
            case .accessoryCorner:
                LogoMark(serviceID: item.serviceID)
                    .padding(4)
                    .widgetLabel {
                        Gauge(value: percent, in: 0...100) { Text("\(Int(percent))%") }
                            .tint(QuotaTheme.levelColor(percent: percent))
                    }
            case .accessoryRectangular:
                RectangularView(item: item, percent: percent, date: entry.date)
            case .accessoryInline:
                Text("\(item.service) \(Int(percent))% · \(item.periodLabel ?? item.name)")
            default:
                Gauge(value: percent, in: 0...100) {
                    LogoMark(serviceID: item.serviceID)
                } currentValueLabel: {
                    Text("\(Int(percent))")
                        .font(.system(.body, design: .rounded).bold())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(QuotaTheme.levelColor(percent: percent))
                .accessibilityLabel("\(item.service) \(Int(percent))퍼센트")
            }
        } else {
            // 아직 iCloud 미러를 받지 못한 상태
            switch family {
            case .accessoryInline:
                Text("QuotaBar 동기화 대기")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text("QuotaBar").font(.headline)
                    Text("Mac과 동기화 대기 중").font(.caption2)
                }
            default:
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
        }
    }
}

private struct RectangularView: View {
    let item: WidgetQuotaItem
    let percent: Double
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                LogoMark(serviceID: item.serviceID)
                    .frame(width: 14, height: 14)
                Text(item.service).font(.headline).lineLimit(1)
                Spacer()
                Text("\(Int(percent))%").font(.headline).monospacedDigit()
            }
            Gauge(value: percent, in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(QuotaTheme.levelColor(percent: percent))
            Text(item.name).font(.caption2).lineLimit(1)
            if let resetsAt = item.resetsAt, resetsAt > date {
                Text("\(QuotaFormat.remaining(resetsAt.timeIntervalSince(date))) 후 리셋")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.service) \(item.name) \(Int(percent))퍼센트")
    }
}

#Preview(as: .accessoryRectangular) {
    QuotaBarWatchComplication()
} timeline: {
    WatchQuotaEntry(date: Date(), item: WidgetSnapshot.sample.items.first)
}
