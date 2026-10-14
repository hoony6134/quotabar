import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 구성 (표시할 쿼터 선택)

/// 컴플리케이션 구성. watchOS는 파라미터 편집 UI가 없어 recommendations()로만 값이 정해진다.
/// AppEntity 파라미터를 추천에 넣으면 WidgetKit이 추천을 만들다가 익스텐션이 크래시하므로(→ 위젯 전체가 목록에서 사라짐)
/// 단순 String/Bool 파라미터만 쓴다.
struct WatchQuotaConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "QuotaBar 설정"
    static var description = IntentDescription("컴플리케이션에 표시할 쿼터를 선택합니다.")

    /// 표시할 쿼터 id ("<accountID>::<quotaKey>", 스냅샷과 동일). nil이면 가장 높은 사용률.
    @Parameter(title: "쿼터 ID")
    var quotaID: String?

    /// 모든 쿼터를 번갈아 표시
    @Parameter(title: "전체 순환", default: false)
    var rotateAll: Bool
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
        // 워치 앱이 iPhone/iCloud에서 받으면 바로 reload되고, 아니어도 15분마다 다시 읽는다.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }

    /// watchOS는 페이스 편집에서 인텐트 파라미터를 직접 고르는 UI가 없고, 이 추천 목록만 컴플리케이션 목록에 보여준다.
    /// "가장 높은 사용률"은 별도의 정적 위젯(QuotaBarWatchComplication)이 맡으므로 여기선 항목별 구성만 준다.
    func recommendations() -> [AppIntentRecommendation<WatchQuotaConfigIntent>] {
        let items = WidgetSnapshot.load()?.items ?? []
        var result: [AppIntentRecommendation<WatchQuotaConfigIntent>] = []
        if items.count > 1 {
            var intent = WatchQuotaConfigIntent()
            intent.rotateAll = true
            result.append(AppIntentRecommendation(intent: intent, description: "전체 순환"))
        }
        for item in items.prefix(12) {
            var intent = WatchQuotaConfigIntent()
            intent.quotaID = item.id
            // 보간(\(...))이 들어간 LocalizedStringResource를 넘기면 WidgetKit이 트랩하므로 완성된 문자열을 키로 넘긴다.
            let label = "\(item.title) · \(item.name)"
            result.append(AppIntentRecommendation(intent: intent, description: LocalizedStringResource(stringLiteral: label)))
        }
        return result
    }

    /// 사용자가 고른 항목 (스냅샷에 있는 것만). 선택이 없으면 빈 배열 → 가장 높은 사용률.
    private static func picked(_ snapshot: WidgetSnapshot, _ configuration: WatchQuotaConfigIntent) -> [WidgetQuotaItem] {
        if configuration.rotateAll { return snapshot.items }
        guard let id = configuration.quotaID else { return [] }
        return snapshot.items.filter { $0.id == id }
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

// MARK: - 기본(정적) 타임라인 — 가장 높은 사용률

/// 설정 없는 기본 컴플리케이션. 인텐트 구성과 무관하게 항상 컴플리케이션 목록에 나오고,
/// 기존 페이스에 올려둔 컴플리케이션(같은 kind)도 그대로 살아 있다.
struct WatchTopQuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchQuotaEntry {
        WatchQuotaEntry(date: Date(), item: WidgetSnapshot.sample.items.first)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchQuotaEntry) -> Void) {
        let pool = context.isPreview ? WidgetSnapshot.sample : (WidgetSnapshot.load() ?? .sample)
        let now = Date()
        completion(WatchQuotaEntry(date: now, item: Self.top(pool.items, at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchQuotaEntry>) -> Void) {
        let now = Date()
        let items = WidgetSnapshot.load()?.items ?? []
        let end = now.addingTimeInterval(WatchQuotaProvider.horizon)
        var dates: Set<Date> = [now]
        for reset in items.compactMap(\.resetsAt) where reset > now && reset < end {
            dates.insert(reset.addingTimeInterval(1))
        }
        let entries = dates.sorted().map { WatchQuotaEntry(date: $0, item: Self.top(items, at: $0)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    static func top(_ items: [WidgetQuotaItem], at date: Date) -> WidgetQuotaItem? {
        items.max { $0.effectivePercent(at: date) < $1.effectivePercent(at: date) }
    }
}

// MARK: - 위젯 정의

@main
struct QuotaBarWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaBarWatchComplication()
        QuotaBarWatchPickedComplication()
    }
}

private let watchFamilies: [WidgetFamily] = [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]

/// 기본: 가장 높은 사용률 (기존 kind 유지 → 이미 페이스에 올린 컴플리케이션이 깨지지 않는다)
struct QuotaBarWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuotaBarWatchComplication", provider: WatchTopQuotaProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuotaBar")
        .description("가장 사용률이 높은 AI 구독 한도를 보여줍니다.")
        .supportedFamilies(watchFamilies)
    }
}

/// 선택: 특정 한도 하나 또는 전체 순환
struct QuotaBarWatchPickedComplication: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarWatchPickedComplication",
                               intent: WatchQuotaConfigIntent.self,
                               provider: WatchQuotaProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuotaBar 한도 선택")
        .description("선택한 AI 구독 한도를 보여줍니다. 전체 순환을 고르면 번갈아 표시합니다.")
        .supportedFamilies(watchFamilies)
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
                Text("\(item.title) \(Int(percent))% · \(item.periodLabel ?? item.name)")
            default:
                Gauge(value: percent, in: 0...100) {
                    LogoMark(serviceID: item.serviceID)
                } currentValueLabel: {
                    Text("\(Int(percent))")
                        .font(.system(.body, design: .rounded).bold())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(QuotaTheme.levelColor(percent: percent))
                .accessibilityLabel("\(item.title) \(Int(percent))퍼센트")
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
                Text(item.title).font(.headline).lineLimit(1)
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
        .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }
}

#Preview(as: .accessoryRectangular) {
    QuotaBarWatchComplication()
} timeline: {
    WatchQuotaEntry(date: Date(), item: WidgetSnapshot.sample.items.first)
}
