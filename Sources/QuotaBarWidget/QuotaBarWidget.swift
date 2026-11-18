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
                            title: "\($0.title) · \($0.name)",
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
    /// 위젯 편집에서 고른 쿼터 수 (nil = 고르지 않음 → 위젯 크기별 기본 개수)
    var selectionCount: Int? = nil

    /// 이 위젯에 그릴 개수: 고른 수(없으면 기본값)를 위젯 크기의 최대치와 실제 항목 수로 자른다.
    func shownCount(default fallback: Int, max limit: Int) -> Int {
        let wanted = selectionCount ?? fallback
        return Swift.max(1, Swift.min(wanted, limit, snapshot?.items.count ?? 0))
    }
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
                          snapshot: Self.filtered(WidgetSnapshot.load() ?? .sample, by: configuration),
                          selectionCount: Self.selectionCount(configuration))
    }

    func timeline(for configuration: QuotaWidgetConfigIntent,
                  in context: Context) async -> Timeline<QuotaEntry> {
        let now = Date()
        let snapshot = Self.filtered(WidgetSnapshot.load(), by: configuration)
        let count = Self.selectionCount(configuration)
        var entries = [QuotaEntry(date: now, snapshot: snapshot, selectionCount: count)]
        // 리셋 시각이 지나는 순간 0%로 바뀌도록 가까운 리셋 시각마다 엔트리를 추가한다.
        let upcoming = (snapshot?.items ?? [])
            .compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
            .sorted()
        for date in Array(Set(upcoming)).sorted().prefix(6) {
            entries.append(QuotaEntry(date: date.addingTimeInterval(1), snapshot: snapshot, selectionCount: count))
        }
        // 앱이 갱신하면 reloadAllTimelines()가 호출되지만, 앱이 꺼져 있어도 15분마다 다시 읽는다.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }

    static func selectionCount(_ configuration: QuotaWidgetConfigIntent) -> Int? {
        guard let count = configuration.items?.count, count > 0 else { return nil }
        return count
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
        QuotaGaugeWidget()
        QuotaTileWidget()
        QuotaSingleWidget()
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
        .configurationDisplayName("QuotaBar 목록")
        .description("AI 구독 사용률을 한눈에. 위젯 편집에서 표시할 쿼터를 고를 수 있습니다.")
        .supportedFamilies(families)
    }
}

/// 반원 게이지 — 작게 1개, 중간 3개, 크게 6개
struct QuotaGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarGaugeWidget",
                               intent: QuotaWidgetConfigIntent.self,
                               provider: QuotaProvider()) { entry in
            GaugeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackdrop(snapshot: entry.snapshot, date: entry.date)
                }
        }
        .configurationDisplayName("QuotaBar 게이지")
        .description("사용률을 게이지로 보여 줍니다. 위젯 편집에서 고른 개수에 맞춰 배치가 바뀝니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 큰 숫자 타일 — 작게 2개, 중간 4개, 크게 6개
struct QuotaTileWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarTileWidget",
                               intent: QuotaWidgetConfigIntent.self,
                               provider: QuotaProvider()) { entry in
            TileWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackdrop(snapshot: entry.snapshot, date: entry.date)
                }
        }
        .configurationDisplayName("QuotaBar 타일")
        .description("쿼터마다 큰 숫자와 막대를 타일로 보여 줍니다. 위젯 편집에서 고른 개수에 맞춰 배치가 바뀝니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 쿼터 하나 — 작게(큰 숫자), 중간(가로로 긴 타일), 크게(큰 숫자)
struct QuotaSingleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarSingleWidget",
                               intent: QuotaWidgetConfigIntent.self,
                               provider: QuotaProvider()) { entry in
            TileWidgetView(entry: entry, single: true)
                .containerBackground(for: .widget) {
                    WidgetBackdrop(snapshot: entry.snapshot, date: entry.date)
                }
        }
        .configurationDisplayName("QuotaBar 단일")
        .description("쿼터 하나를 크게 보여 줍니다. 위젯 편집에서 고른 첫 번째 쿼터(기본은 가장 높은 사용률)를 씁니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
                Text(top.title)
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
        .accessibilityLabel("\(top.title) \(top.name) \(Int(percent))퍼센트 사용")
    }
}

/// Medium/Large: 쿼터 목록
private struct ListView: View {
    let snapshot: WidgetSnapshot
    let date: Date
    let maxRows: Int
    var showsRefresh = true

    /// 중간 크기(3행)는 행을 두 줄로 줄이고 남는 높이를 행 사이에 고르게 나눈다.
    private var compact: Bool { maxRows <= 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 7) {
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
            if compact {
                ForEach(snapshot.items.prefix(maxRows)) { item in
                    Spacer(minLength: 6)
                    compactRow(item)
                }
                Spacer(minLength: 0)
            } else {
                ForEach(snapshot.items.prefix(maxRows)) { item in
                    row(item)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func compactRow(_ item: WidgetQuotaItem) -> some View {
        let percent = item.effectivePercent(at: date)
        HStack(spacing: 8) {
            ServiceMark(serviceID: item.serviceID, colorHex: item.colorHex, size: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ResetLine(item: item, date: date, size: 9)
                        .layoutPriority(-1)
                    Text("\(Int(percent))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(percent >= 90 ? QuotaTheme.critical : .primary)
                }
                QuotaBarGauge(percent: percent, height: 4, marker: item.elapsedFraction(at: date))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }

    @ViewBuilder
    private func row(_ item: WidgetQuotaItem) -> some View {
        let percent = item.effectivePercent(at: date)
        HStack(spacing: 8) {
            ServiceMark(serviceID: item.serviceID, colorHex: item.colorHex, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
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
                QuotaBarGauge(percent: percent, height: 5, marker: item.elapsedFraction(at: date))
                ResetLine(item: item, date: date, size: 9)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }
}

// MARK: - 게이지 위젯

/// 아래가 트인 270° 게이지
private struct ArcGauge: View {
    let percent: Double
    var lineWidth: CGFloat = 8
    var fontSize: CGFloat = 20

    var body: some View {
        let fraction = min(max(percent, 0), 100) / 100
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(QuotaTheme.levelColor(percent: percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            VStack(spacing: 0) {
                Text("\(Int(percent))")
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text("%")
                    .font(.system(size: fontSize * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .rotationEffect(.degrees(-135))
        }
        .rotationEffect(.degrees(135))
    }
}

/// 제목(로고 + 계정) · 쿼터 이름 두 줄
private struct ItemCaption: View {
    let item: WidgetQuotaItem
    var titleSize: CGFloat = 10
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 3) {
                ServiceMark(serviceID: item.serviceID, colorHex: item.colorHex, size: titleSize + 1)
                Text(item.title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(1)
            }
            Text(item.name)
                .font(.system(size: titleSize - 1))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 지름을 정한 게이지 + 아래 캡션
private struct GaugeCell: View {
    let item: WidgetQuotaItem
    let date: Date
    let diameter: CGFloat

    var body: some View {
        let percent = item.effectivePercent(at: date)
        VStack(spacing: 5) {
            ArcGauge(percent: percent, lineWidth: max(5, diameter * 0.085), fontSize: diameter * 0.27)
                .frame(width: diameter, height: diameter)
            ItemCaption(item: item, titleSize: diameter >= 100 ? 12 : 10)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }
}

/// 게이지 하나를 크게 + 옆(또는 아래)에 자세한 정보
private struct GaugeFeature: View {
    let item: WidgetQuotaItem
    let date: Date
    let diameter: CGFloat
    var vertical = false

    var body: some View {
        let percent = item.effectivePercent(at: date)
        let gauge = ArcGauge(percent: percent, lineWidth: diameter * 0.09, fontSize: diameter * 0.28)
            .frame(width: diameter, height: diameter)
        let info = VStack(alignment: vertical ? .center : .leading, spacing: 4) {
            ItemCaption(item: item, titleSize: 13, alignment: vertical ? .center : .leading)
            ResetLine(item: item, date: date, size: 11)
        }
        Group {
            if vertical {
                VStack(spacing: 12) { gauge; info }
            } else {
                HStack(spacing: 16) { gauge; info; Spacer(minLength: 0) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }
}

/// 항목을 열 수에 맞춰 줄 단위로 배치
private struct ItemGrid<Cell: View>: View {
    let items: [WidgetQuotaItem]
    let columns: Int
    var spacing: CGFloat = 8
    @ViewBuilder let cell: (WidgetQuotaItem) -> Cell

    var body: some View {
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)]) { cell($0) }
                }
            }
        }
    }
}

/// 게이지 수는 위젯 편집에서 고른 쿼터 수를 따른다 (안 고르면 작게 1 · 중간 3 · 크게 6).
private struct GaugeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
            switch family {
            case .systemSmall: small(snapshot)
            case .systemLarge: large(snapshot)
            default: medium(snapshot)
            }
        } else {
            EmptyDataView()
        }
    }

    @ViewBuilder
    private func small(_ snapshot: WidgetSnapshot) -> some View {
        let items = Array(snapshot.items.prefix(entry.shownCount(default: 1, max: 2)))
        if items.count == 1 {
            GaugeFeature(item: items[0], date: entry.date, diameter: 92, vertical: true)
        } else {
            HStack(spacing: 8) {
                ForEach(items) { GaugeCell(item: $0, date: entry.date, diameter: 56) }
            }
        }
    }

    @ViewBuilder
    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        let items = Array(snapshot.items.prefix(entry.shownCount(default: 3, max: 4)))
        if items.count == 1 {
            GaugeFeature(item: items[0], date: entry.date, diameter: 96)
        } else {
            let diameter: CGFloat = [2: 78, 3: 68, 4: 56][items.count] ?? 56
            HStack(spacing: 10) {
                ForEach(items) { GaugeCell(item: $0, date: entry.date, diameter: diameter) }
            }
        }
    }

    @ViewBuilder
    private func large(_ snapshot: WidgetSnapshot) -> some View {
        let items = Array(snapshot.items.prefix(entry.shownCount(default: 6, max: 6)))
        VStack(spacing: 10) {
            header(snapshot)
            Spacer(minLength: 0)
            switch items.count {
            case 1:
                GaugeFeature(item: items[0], date: entry.date, diameter: 160, vertical: true)
            case 2:
                HStack(spacing: 12) {
                    ForEach(items) { GaugeCell(item: $0, date: entry.date, diameter: 112) }
                }
            case 3, 4:
                ItemGrid(items: items, columns: 2, spacing: 16) { GaugeCell(item: $0, date: entry.date, diameter: 88) }
            default:
                ItemGrid(items: items, columns: 3, spacing: 16) { GaugeCell(item: $0, date: entry.date, diameter: 72) }
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("QuotaBar").font(.caption.bold())
            StaleBadge(snapshot: snapshot, date: entry.date)
            Spacer()
            if !entry.isPlaceholder { RefreshButton() }
        }
    }
}

// MARK: - 타일 위젯

private enum TileStyle {
    /// 하나를 크게 (큰 숫자 + 막대 + 리셋)
    case big
    /// 가로로 긴 타일 (왼쪽 정보, 오른쪽 큰 숫자)
    case wide
    /// 기본 타일
    case regular
    /// 낮은 칸용 — 한 줄 제목 + 숫자, 아래 막대
    case compact
}

private struct QuotaTile: View {
    let item: WidgetQuotaItem
    let date: Date
    var style: TileStyle = .regular
    /// big 스타일 숫자 크기
    var bigNumber: CGFloat = 52

    var body: some View {
        let percent = item.effectivePercent(at: date)
        content(percent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title) \(item.name) \(Int(percent))퍼센트")
    }

    private func number(_ percent: Double, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int(percent))")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .foregroundStyle(QuotaTheme.levelColor(percent: percent))
            Text("%")
                .font(.system(size: max(9, size * 0.38), weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func content(_ percent: Double) -> some View {
        let marker = item.elapsedFraction(at: date)
        switch style {
        case .big:
            VStack(alignment: .leading, spacing: 6) {
                ItemCaption(item: item, titleSize: 13, alignment: .leading)
                Spacer(minLength: 0)
                number(percent, size: bigNumber)
                QuotaBarGauge(percent: percent, height: 6, marker: marker)
                ResetLine(item: item, date: date, size: 10)
            }
            .padding(14)
        case .wide:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        ItemCaption(item: item, titleSize: 12, alignment: .leading)
                        ResetLine(item: item, date: date, size: 10)
                    }
                    Spacer(minLength: 8)
                    number(percent, size: 40)
                }
                QuotaBarGauge(percent: percent, height: 5, marker: marker)
            }
            .padding(12)
        case .regular:
            VStack(alignment: .leading, spacing: 4) {
                ItemCaption(item: item, titleSize: 10, alignment: .leading)
                Spacer(minLength: 0)
                number(percent, size: 24)
                QuotaBarGauge(percent: percent, height: 4, marker: marker)
            }
            .padding(10)
        case .compact:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ItemCaption(item: item, titleSize: 10, alignment: .leading)
                    Spacer(minLength: 4)
                    number(percent, size: 17)
                }
                QuotaBarGauge(percent: percent, height: 3, marker: marker)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
    }
}

/// 타일 수는 고른 쿼터 수를 따른다 (안 고르면 작게 1 · 중간 4 · 크게 6). `single`이면 항상 하나.
private struct TileWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry
    var single = false

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
            let date = entry.date
            switch family {
            case .systemSmall:
                let items = Array(snapshot.items.prefix(single ? 1 : entry.shownCount(default: 1, max: 2)))
                if items.count == 1 {
                    QuotaTile(item: items[0], date: date, style: .big, bigNumber: 40)
                } else {
                    VStack(spacing: 6) { ForEach(items) { QuotaTile(item: $0, date: date, style: .compact) } }
                }
            case .systemLarge:
                let items = Array(snapshot.items.prefix(single ? 1 : entry.shownCount(default: 6, max: 6)))
                switch items.count {
                case 1:
                    QuotaTile(item: items[0], date: date, style: .big, bigNumber: 84)
                case 2:
                    VStack(spacing: 8) { ForEach(items) { QuotaTile(item: $0, date: date, style: .wide) } }
                default:
                    ItemGrid(items: items, columns: 2) { QuotaTile(item: $0, date: date, style: .regular) }
                }
            default:
                let items = Array(snapshot.items.prefix(single ? 1 : entry.shownCount(default: 4, max: 4)))
                switch items.count {
                case 1:
                    QuotaTile(item: items[0], date: date, style: .wide)
                case 2, 3:
                    HStack(spacing: 8) { ForEach(items) { QuotaTile(item: $0, date: date, style: .regular) } }
                default:
                    ItemGrid(items: items, columns: 2) { QuotaTile(item: $0, date: date, style: .compact) }
                }
            }
        } else {
            EmptyDataView()
        }
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
        .accessibilityLabel("\(item.title) \(Int(percent))퍼센트")
    }
}

private struct AccessoryRectangularView: View {
    let item: WidgetQuotaItem
    let date: Date

    var body: some View {
        let percent = item.effectivePercent(at: date)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.title).font(.headline).lineLimit(1)
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
        Text("\(item.title) \(Int(item.effectivePercent(at: date)))% · \(item.periodLabel ?? item.name)")
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
