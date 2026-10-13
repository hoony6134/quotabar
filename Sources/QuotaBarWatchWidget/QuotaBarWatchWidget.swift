import WidgetKit
import SwiftUI

// MARK: - 타임라인

struct WatchQuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?

    /// 가장 사용률이 높은 쿼터 (리셋이 지난 항목은 0%로 본다)
    var top: WidgetQuotaItem? {
        snapshot?.items.max { $0.effectivePercent(at: date) < $1.effectivePercent(at: date) }
    }
}

struct WatchQuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchQuotaEntry {
        WatchQuotaEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchQuotaEntry) -> Void) {
        let snapshot: WidgetSnapshot = context.isPreview ? WidgetSnapshot.sample : (WidgetSnapshot.load() ?? WidgetSnapshot.sample)
        completion(WatchQuotaEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchQuotaEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        var entries = [WatchQuotaEntry(date: now, snapshot: snapshot)]
        // 리셋 시각이 지나는 순간 0%로 바뀌도록 가까운 리셋 시각마다 엔트리를 추가한다.
        let upcoming = (snapshot?.items ?? [])
            .compactMap(\.resetsAt)
            .filter { $0 > now && $0 < now.addingTimeInterval(6 * 3600) }
        for date in Array(Set(upcoming)).sorted().prefix(6) {
            entries.append(WatchQuotaEntry(date: date.addingTimeInterval(1), snapshot: snapshot))
        }
        // 워치 위젯은 갱신 예산이 작으므로 30분 간격으로 다시 읽는다.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
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
        StaticConfiguration(kind: "QuotaBarWatchComplication", provider: WatchQuotaProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("QuotaBar")
        .description("가장 사용률이 높은 AI 구독 한도를 보여줍니다.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - 뷰

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchQuotaEntry

    var body: some View {
        if let item = entry.top {
            let percent = item.effectivePercent(at: entry.date)
            switch family {
            case .accessoryCorner:
                Text("\(Int(percent))%")
                    .font(.system(.title3, design: .rounded).bold())
                    .widgetLabel {
                        Gauge(value: percent, in: 0...100) { Text(item.service) }
                            .tint(QuotaTheme.levelColor(percent: percent))
                    }
            case .accessoryRectangular:
                RectangularView(item: item, percent: percent, date: entry.date)
            case .accessoryInline:
                Text("\(item.service) \(Int(percent))% · \(item.periodLabel ?? item.name)")
            default:
                Gauge(value: percent, in: 0...100) {
                    Text(item.service.prefix(1))
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
            HStack {
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
    WatchQuotaEntry(date: Date(), snapshot: .sample)
}
