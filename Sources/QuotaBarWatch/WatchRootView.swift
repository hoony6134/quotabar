import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchMirrorModel

    var body: some View {
        NavigationStack {
            Group {
                if model.hasData, let snapshot = model.snapshot {
                    List {
                        Section {
                            SummaryRow(snapshot: snapshot)
                        }
                        Section("서비스") {
                            ForEach(model.sections) { section in
                                NavigationLink(value: section.id) {
                                    ServiceRow(section: section)
                                }
                            }
                        }
                        Section {
                            Button {
                                Task { await model.requestRefresh() }
                            } label: {
                                Label(model.isRefreshing ? "Mac에 요청 중…" : "새로고침",
                                      systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isRefreshing)
                            if model.demoMode {
                                Button {
                                    model.demoMode = false
                                } label: {
                                    Label("데모 끄기", systemImage: "xmark.circle")
                                }
                            }
                        } footer: {
                            Text("사용률은 Mac의 QuotaBar가 iCloud로 전달한 값입니다.")
                        }
                    }
                    .navigationDestination(for: String.self) { id in
                        if let section = model.sections.first(where: { $0.id == id }) {
                            ServiceDetailView(section: section)
                        }
                    }
                } else {
                    EmptyStateView()
                }
            }
            .navigationTitle("QuotaBar")
        }
    }
}

// MARK: - 요약

/// 가장 높은 사용률 링 + 동기화 상태
private struct SummaryRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let top = snapshot.items.max { $0.effectivePercent(at: context.date) < $1.effectivePercent(at: context.date) }
            let percent = top?.effectivePercent(at: context.date) ?? 0
            HStack(spacing: 10) {
                QuotaRing(percent: percent, lineWidth: 7) {
                    Text("\(Int(percent))")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    if let top {
                        Text(top.service).font(.headline)
                        Text(top.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(syncText(now: context.date))
                        .font(.caption2)
                        .foregroundStyle(snapshot.isStale(at: context.date) ? QuotaTheme.caution : .secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(top.map { "\($0.service) \($0.name) \(Int(percent))퍼센트 사용, \(QuotaTheme.levelLabel(percent: percent))" } ?? "")
        }
    }

    private func syncText(now: Date) -> String {
        if snapshot.isDemo == true { return "데모 데이터" }
        let ago = QuotaFormat.ago(snapshot.generatedAt, now: now)
        return snapshot.isStale(at: now) ? "오래됨 · \(ago)" : "갱신 \(ago)"
    }
}

private struct ServiceRow: View {
    let section: WatchServiceSection

    var body: some View {
        let percent = section.worst
        HStack(spacing: 8) {
            ServiceMark(serviceID: section.first.serviceID, colorHex: section.first.colorHex, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.first.service).font(.footnote.weight(.semibold))
                if let plan = section.items.compactMap(\.planName).first {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("\(Int(percent))%")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(QuotaTheme.levelColor(percent: percent))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.first.service) 최대 \(Int(percent))퍼센트 사용")
    }
}

// MARK: - 서비스 상세

private struct ServiceDetailView: View {
    let section: WatchServiceSection

    var body: some View {
        List {
            ForEach(section.items) { item in
                QuotaDetailRow(item: item)
            }
        }
        .navigationTitle(section.first.service)
    }
}

private struct QuotaDetailRow: View {
    let item: WidgetQuotaItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let percent = item.effectivePercent(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.footnote).lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(Int(percent))%")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(QuotaTheme.levelColor(percent: percent))
                }
                QuotaBarGauge(percent: percent, height: 6)
                Text(QuotaFormat.resetText(item, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let usage = item.usageText, !usage.hasSuffix("%") {
                    Text(usage).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                if item.syncError != nil {
                    Label("마지막 조회 실패", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(QuotaTheme.caution)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name) \(Int(percent))퍼센트 사용. \(QuotaFormat.resetText(item, now: context.date))")
        }
    }
}

// MARK: - 데이터 없음

private struct EmptyStateView: View {
    @EnvironmentObject var model: WatchMirrorModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("아직 받은 데이터가 없어요")
                    .font(.footnote.weight(.semibold))
                Text("Mac에서 QuotaBar를 실행하고 같은 Apple ID로 iCloud에 로그인하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("다시 확인") { model.reload() }
                Button("데모 보기") { model.demoMode = true }
            }
            .padding(.horizontal, 4)
        }
    }
}
