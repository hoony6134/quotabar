import WidgetKit
import SwiftUI
import AppIntents
import AppKit

// MARK: - 제품 로고 (위젯 번들 리소스)

private enum WidgetLogo {
    private static var cache: [String: NSImage] = [:]

    static func image(for serviceID: String?) -> NSImage? {
        guard let serviceID, !serviceID.isEmpty else { return nil }
        if let cached = cache[serviceID] { return cached }
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        let url = bundles.lazy.compactMap { bundle in
            bundle.url(forResource: serviceID, withExtension: "png", subdirectory: "Logos")
                ?? bundle.url(forResource: serviceID, withExtension: "png")
        }.first
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        cache[serviceID] = image
        return image
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0)
    }
}

/// 브랜드 색 배경 + 흰색 제품 로고 배지
private struct ServiceLogoBadge: View {
    let item: WidgetQuotaItem
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let logo = WidgetLogo.image(for: item.serviceID) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background((Color(hex: item.colorHex) ?? .gray).gradient,
                    in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

private extension WidgetQuotaItem {
    var symbolName: String {
        switch serviceID {
        case "claude": return "sparkle"
        case "chatgpt": return "bubble.left.and.bubble.right.fill"
        case "googleAI": return "diamond.fill"
        case "antigravity": return "atom"
        case "cursor": return "cursorarrow.rays"
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkle"
        }
    }
}

// MARK: - 새로고침 인텐트 (인터랙티브 위젯)

/// 위젯의 새로고침 버튼: 분산 알림으로 QuotaBar 앱에 갱신을 요청한다.
struct RefreshQuotasIntent: AppIntent {
    static var title: LocalizedStringResource = "AI 쿼터 새로고침"
    static var description = IntentDescription("QuotaBar 앱에 사용량 갱신을 요청합니다.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(QuotaWidgetShared.refreshNotificationName),
            object: nil, userInfo: nil, deliverImmediately: true)
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

/// 위젯 우클릭 → "위젯 편집"에서 표시할 쿼터를 고른다.
struct QuotaWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "AI 쿼터 설정"
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
        QuotaEntry(date: Date(),
                   snapshot: Self.filtered(WidgetSnapshot.load() ?? .sample, by: configuration))
    }

    func timeline(for configuration: QuotaWidgetConfigIntent,
                  in context: Context) async -> Timeline<QuotaEntry> {
        let entry = QuotaEntry(date: Date(),
                               snapshot: Self.filtered(WidgetSnapshot.load(), by: configuration))
        // 앱이 갱신할 때마다 reloadAllTimelines()를 호출하지만,
        // 앱이 꺼져 있어도 15분마다 파일을 다시 읽는다.
        let next = Date().addingTimeInterval(15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
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
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaBarWidget",
                               intent: QuotaWidgetConfigIntent.self,
                               provider: QuotaProvider()) { entry in
            QuotaWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("AI 쿼터")
        .description("QuotaBar의 AI 구독 사용률을 표시합니다. 위젯 편집에서 표시할 쿼터를 고를 수 있습니다.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
                SmallView(snapshot: snapshot, showsRefresh: !entry.isPlaceholder)
            case .systemLarge:
                ListView(snapshot: snapshot, maxRows: 7, showsRefresh: !entry.isPlaceholder)
            default:
                ListView(snapshot: snapshot, maxRows: 3, showsRefresh: !entry.isPlaceholder)
            }
        } else {
            EmptyDataView()
        }
    }

    static func color(_ percent: Double) -> Color {
        switch percent {
        case ..<50:  return .green
        case ..<75:  return .yellow
        case ..<90:  return .orange
        default:     return .red
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
            .padding(.horizontal, labelled ? 7 : 0)
            .frame(width: labelled ? nil : 24, height: 24)
            .padding(.vertical, labelled ? 4 : 0)
            .background(Color.primary.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .help("새로고침")
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
                RefreshButton(labelled: false)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("동기화 대기 중")
                    .font(.headline)
                    .lineLimit(1)
                Text("앱을 열면 쿼터가 표시됩니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            VStack(spacing: 5) {
                placeholderBar(width: 0.72)
                placeholderBar(width: 0.46)
                placeholderBar(width: 0.58)
            }
        }
    }

    private func placeholderBar(width: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(width: proxy.size.width * width)
        }
        .frame(height: 5)
    }
}

private struct WidgetResetSummary: View {
    let item: WidgetQuotaItem
    var compact = false

    var body: some View {
        Text(text)
        .font(.system(size: compact ? 8 : 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var text: String {
        guard let resetsAt = item.resetsAt else {
            return item.periodLabel.map { "\($0) 리셋 시간 없음" } ?? "리셋 시간 없음"
        }
        let remaining = resetsAt.timeIntervalSince(Date())
        if remaining <= 0 { return "곧 리셋" }
        let prefix = item.periodLabel.map { "\($0) · " } ?? ""
        return "\(prefix)\(Self.format(remaining)) 후 리셋"
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = max(Int(interval), 0)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }
}

/// Small: 첫 번째(선택 시 첫 선택, 기본은 최고 사용률) 쿼터를 링 게이지로
private struct SmallView: View {
    let snapshot: WidgetSnapshot
    var showsRefresh = true

    var body: some View {
        let top = snapshot.items[0]
        let percent = min(max(top.percent, 0), 100)
        VStack(spacing: 6) {
            HStack {
                ServiceLogoBadge(item: top, size: 16)
                Text(top.service)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                if showsRefresh {
                    RefreshButton(labelled: false)
                }
            }
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: percent / 100)
                    .stroke(QuotaWidgetView.color(percent),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(percent))%")
                    .font(.system(.title3, design: .rounded).bold())
                    .monospacedDigit()
            }
            .frame(maxHeight: .infinity)
            Text(top.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            WidgetResetSummary(item: top, compact: true)
        }
    }
}

/// Medium/Large: 쿼터 목록 (행마다 세션 리셋 시간 + 헤더 새로고침)
private struct ListView: View {
    let snapshot: WidgetSnapshot
    let maxRows: Int
    var showsRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.caption)
                Text("AI 쿼터")
                    .font(.caption.bold())
                Spacer()
                if showsRefresh {
                    RefreshButton()
                } else {
                    Text("미리보기")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .padding(.bottom, 2)
            ForEach(snapshot.items.prefix(maxRows)) { item in
                row(item)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func row(_ item: WidgetQuotaItem) -> some View {
        let percent = min(max(item.percent, 0), 100)
        HStack(spacing: 6) {
            ServiceLogoBadge(item: item, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.service)
                    .font(.caption2.bold())
                    .lineLimit(1)
                Text(item.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                WidgetResetSummary(item: item, compact: true)
            }
            .frame(width: 92, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                GeometryReader { proxy in
                    Capsule()
                        .fill(QuotaWidgetView.color(percent))
                        .frame(width: proxy.size.width * (percent / 100.0))
                }
            }
            .frame(height: 5)

            Text("\(Int(percent))%")
                .font(.caption2.bold())
                .monospacedDigit()
                .foregroundStyle(percent >= 90 ? .red : .primary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

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
