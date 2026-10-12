import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 새로고침 인텐트 (인터랙티브 위젯)

/// 위젯의 새로고침 버튼.
/// - macOS: 분산 알림으로 QuotaBar 앱에 갱신을 요청한다.
/// - iOS: iCloud로 Mac에 갱신 요청을 보내고, 위젯은 즉시 최신 미러 데이터를 다시 읽는다.
struct RefreshQuotasIntent: AppIntent {
    static var title: LocalizedStringResource = "QuotaBar 새로고침"
    static var description = IntentDescription("QuotaBar 사용량 갱신을 요청합니다.")
    #if os(macOS)
    static var openAppWhenRun: Bool = true
    #endif

    func perform() async throws -> some IntentResult {
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(QuotaWidgetShared.refreshNotificationName),
            object: nil, userInfo: nil, deliverImmediately: true)
        #else
        QuotaCloudSync.requestRefresh()
        #endif
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - 위젯 구성 (표시할 쿼터 선택)

/// 위젯 편집 UI에 나오는 쿼터 항목. id = "<accountID>::<quotaKey>" (스냅샷과 동일)
struct QuotaItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "쿼터"
    static var defaultQuery = QuotaItemQuery()

    var id: String
    var title: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct QuotaItemQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [QuotaItemEntity] {
        let all = Self.allEntities()
        // 스냅샷에 아직 없는 항목(앱 미실행 등)도 선택값은 보존한다
        return identifiers.map { id in
            all.first { $0.id == id }
                ?? QuotaItemEntity(id: id, title: "알 수 없는 쿼터", subtitle: "")
        }
    }

    func suggestedEntities() async throws -> [QuotaItemEntity] {
        Self.allEntities()
    }

    static func allEntities() -> [QuotaItemEntity] {
        let items = WidgetSnapshot.load()?.items ?? []
        return items.map {
            QuotaItemEntity(id: $0.id,
                            title: "\($0.service) · \($0.name)",
                            subtitle: $0.label)
        }
    }
}

/// 위젯 편집에서 표시할 쿼터를 고른다.
struct QuotaWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "QuotaBar 설정"
    static var description = IntentDescription("위젯에 표시할 쿼터를 선택합니다. 비워두면 사용률 높은 순으로 전체를 표시합니다.")

    @Parameter(title: "표시할 쿼터")
    var items: [QuotaItemEntity]?
}

// MARK: - 타임라인

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var isPlaceholder = false
}

struct QuotaProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), snapshot: .sample, isPlaceholder: true)
    }

    func snapshot(for configuration: QuotaWidgetConfigIntent,
                  in context: Context) async -> QuotaEntry {
        if context.isPreview {
            return QuotaEntry(date: Date(), snapshot: .sample, isPlaceholder: true)
        }
        return QuotaEntry(date: Date(),
                          snapshot: Self.filtered(WidgetSnapshot.load() ?? .sample, by: configuration))
    }

    func timeline(for configuration: QuotaWidgetConfigIntent,
                  in context: Context) async -> Timeline<QuotaEntry> {
        let now = Date()
        let snapshot = Self.filtered(WidgetSnapshot.load(), by: configuration)
        var entries = [QuotaEntry(date: now, snapshot: snapshot)]
        // 리셋 시각이 지나는 순간 0%로 바뀌도록 가까운 리셋 시각마다 엔트리를 추가한다.
        let upcoming = (snapshot?.items ?? [])
            .compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
            .sorted()
        for date in Array(Set(upcoming)).sorted().prefix(6) {
            entries.append(QuotaEntry(date: date.addingTimeInterval(1), snapshot: snapshot))
        }
        // 앱이 갱신하면 reloadAllTimelines()가 호출되지만, 앱이 꺼져 있어도 15분마다 다시 읽는다.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }

    /// 선택된 항목만, 선택한 순서대로 남긴다. 선택이 없으면 전체(사용률 순) 그대로.
    static func filtered(_ snapshot: WidgetSnapshot?,
                         by configuration: QuotaWidgetConfigIntent) -> WidgetSnapshot? {
        guard var snapshot else { return nil }
        guard let selected = configuration.items, !selected.isEmpty else { return snapshot }
        let byID = Dictionary(snapshot.items.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let picked = selected.compactMap { byID[$0.id] }
        if !picked.isEmpty { snapshot.items = picked }
        return snapshot
    }
}

// MARK: - 위젯 정의

@main
struct QuotaBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotaBarWidget()
    }
}

struct QuotaBarWidget: Widget {
    private var families: [WidgetFamily] {
        #if os(iOS)
        return [.systemSmall, .systemMedium, .systemLarge,
                .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        return [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarWidget",
                               intent: QuotaWidgetConfigIntent.self,
                               provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackdrop(snapshot: entry.snapshot, date: entry.date)
                }
        }
        .configurationDisplayName("QuotaBar")
        .description("AI 구독 사용률을 한눈에. 위젯 편집에서 표시할 쿼터를 고를 수 있습니다.")
        .supportedFamilies(families)
    }
}

/// 가장 높은 사용률의 단계 색이 은은하게 번지는 배경
private struct WidgetBackdrop: View {
    let snapshot: WidgetSnapshot?
    let date: Date

    var body: some View {
        let worst = snapshot?.items.map { $0.effectivePercent(at: date) }.max() ?? 0
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [QuotaTheme.levelColor(percent: worst).opacity(0.18), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 220)
        }
    }
}

// MARK: - 뷰

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
            switch family {
            case .systemSmall:
                SmallView(snapshot: snapshot, date: entry.date, showsRefresh: !entry.isPlaceholder)
            case .systemLarge:
                ListView(snapshot: snapshot, date: entry.date, maxRows: 7, showsRefresh: !entry.isPlaceholder)
            #if os(iOS)
            case .accessoryCircular:
                AccessoryCircularView(item: snapshot.items[0], date: entry.date)
            case .accessoryRectangular:
                AccessoryRectangularView(item: snapshot.items[0], date: entry.date)
            case .accessoryInline:
                AccessoryInlineView(item: snapshot.items[0], date: entry.date)
            #endif
            default:
                ListView(snapshot: snapshot, date: entry.date, maxRows: 3, showsRefresh: !entry.isPlaceholder)
            }
        } else {
            EmptyDataView()
        }
    }
}

/// 새로고침 버튼 (AppIntent 기반 인터랙티브 위젯)
private struct RefreshButton: View {
    var labelled = true

    var body: some View {
        Button(intent: RefreshQuotasIntent()) {
            Group {
                if labelled {
                    Label("갱신", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.system(size: labelled ? 10 : 11, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, labelled ? 8 : 0)
            .frame(width: labelled ? nil : 24, height: 24)
            .background(Color.primary.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("새로고침")
    }
}

private struct EmptyDataView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.caption.bold())
                Text("QuotaBar")
                    .font(.caption.bold())
                Spacer()
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("동기화 대기 중")
                    .font(.headline)
                    .lineLimit(1)
                #if os(iOS)
                Text("Mac에서 QuotaBar 2.0을 실행하고 같은 Apple ID로 iCloud에 로그인하세요")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                #else
                Text("앱을 열면 쿼터가 표시됩니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                #endif
            }
        }
    }
}

/// "1시간 24분 후 리셋" — 위젯은 1분마다 다시 그릴 수 없으므로 시스템이 갱신하는 상대 시간을 쓴다.
private struct ResetLine: View {
    let item: WidgetQuotaItem
    let date: Date
    var size: CGFloat = 9

    var body: some View {
        Group {
            if let resetsAt = item.resetsAt, resetsAt > date {
                HStack(spacing: 2) {
                    Text(resetsAt, style: .relative)
                    Text("후 리셋")
                }
            } else if item.resetsAt != nil {
                Text("리셋됨")
            } else {
                Text(item.periodLabel ?? "")
            }
        }
        .font(.system(size: size))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .monospacedDigit()
    }
}

private struct StaleBadge: View {
    let snapshot: WidgetSnapshot
    let date: Date

    var body: some View {
        if snapshot.isStale(at: date) {
            Label(QuotaFormat.ago(snapshot.generatedAt, now: date), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(QuotaTheme.caution)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Small: 첫 번째(선택 시 첫 선택, 기본은 최고 사용률) 쿼터를 링 게이지로
private struct SmallView: View {
    let snapshot: WidgetSnapshot
    let date: Date
    var showsRefresh = true

    var body: some View {
        let top = snapshot.items[0]
        let percent = top.effectivePercent(at: date)
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ServiceMark(serviceID: top.serviceID, colorHex: top.colorHex, size: 18)
                Text(top.service)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showsRefresh { RefreshButton(labelled: false) }
            }
            QuotaRing(percent: percent, lineWidth: 9) {
                VStack(spacing: 0) {
                    Text("\(Int(percent))")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxHeight: .infinity)
            VStack(spacing: 1) {
                Text(top.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                ResetLine(item: top, date: date, size: 9)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(top.service) \(top.name) \(Int(percent))퍼센트 사용")
    }
}

/// Medium/Large: 쿼터 목록
private struct ListView: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let maxRows: Int
    var showsRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.caption.bold())
                    .foregroundStyle(QuotaTheme.levelColor(percent: snapshot.items.first?.effectivePercent(at: date) ?? 0))
                Text("QuotaBar")
                    .font(.caption.bold())
                StaleBadge(snapshot: snapshot, date: date)
                Spacer()
                if showsRefresh { RefreshButton() }
            }
            ForEach(snapshot.items.prefix(maxRows)) { item in
                row(item)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func row(_ item: WidgetQuotaItem) -> some View {
        let percent = item.effectivePercent(at: date)
        HStack(spacing: 8) {
            ServiceMark(serviceID: item.serviceID, colorHex: item.colorHex, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.service)
                        .font(.system(size: 11, weight: .semibold))
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int(percent))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(percent >= 90 ? QuotaTheme.critical : .primary)
                }
                QuotaBarGauge(percent: percent, height: 5)
                ResetLine(item: item, date: date, size: 9)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.service) \(item.name) \(Int(percent))퍼센트")
    }
}

#if os(iOS)
// MARK: - 잠금 화면 위젯

private struct AccessoryCircularView: View {
    let item: WidgetQuotaItem
    let date: Date

    var body: some View {
        let percent = item.effectivePercent(at: date)
        Gauge(value: percent, in: 0...100) {
            Text(item.service.prefix(1))
        } currentValueLabel: {
            Text("\(Int(percent))")
                .font(.system(.body, design: .rounded).bold())
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel("\(item.service) \(Int(percent))퍼센트")
    }
}

private struct AccessoryRectangularView: View {
    let item: WidgetQuotaItem
    let date: Date

    var body: some View {
        let percent = item.effectivePercent(at: date)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.service).font(.headline).lineLimit(1)
                Spacer()
                Text("\(Int(percent))%").font(.headline).monospacedDigit()
            }
            Gauge(value: percent, in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
            Text(item.name).font(.caption2).lineLimit(1)
            ResetLine(item: item, date: date, size: 10)
        }
    }
}

private struct AccessoryInlineView: View {
    let item: WidgetQuotaItem
    let date: Date

    var body: some View {
        Text("\(item.service) \(Int(item.effectivePercent(at: date)))% · \(item.periodLabel ?? item.name)")
    }
}
#endif

#Preview(as: .systemSmall) {
    QuotaBarWidget()
} timeline: {
    QuotaEntry(date: Date(), snapshot: .sample)
}

#Preview(as: .systemMedium) {
    QuotaBarWidget()
} timeline: {
    QuotaEntry(date: Date(), snapshot: .sample)
}

#Preview(as: .systemLarge) {
    QuotaBarWidget()
} timeline: {
    QuotaEntry(date: Date(), snapshot: .sample)
}
