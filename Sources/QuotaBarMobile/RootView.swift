import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: MirrorModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                if model.hasData {
                    DashboardList()
                } else {
                    OnboardingView()
                }
            }
            .navigationTitle("QuotaBar")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .tint(.primary)
    }
}

struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var model: MirrorModel

    var body: some View {
        let worst = model.snapshot?.items.map { $0.effectivePercent() }.max() ?? 0
        ZStack {
            (scheme == .dark
             ? LinearGradient(colors: [QuotaTheme.backdropTop, QuotaTheme.backdropBottom],
                              startPoint: .top, endPoint: .bottom)
             : LinearGradient(colors: [Color(white: 0.97), Color(white: 0.93)],
                              startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [QuotaTheme.levelColor(percent: worst).opacity(scheme == .dark ? 0.22 : 0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 대시보드

struct DashboardList: View {
    @EnvironmentObject var model: MirrorModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if let snapshot = model.snapshot {
                    SyncBanner(snapshot: snapshot)
                    HeroCard(snapshot: snapshot)
                    ForEach(model.sections) { section in
                        ServiceCard(section: section)
                    }
                    Text("사용률은 Mac의 QuotaBar가 조회해 iCloud로 전달한 값입니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .refreshable { await model.pullRefresh() }
    }
}

/// Mac이 오래 응답하지 않을 때(잠자기/종료) 알려준다.
struct SyncBanner: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let stale = snapshot.isStale(at: context.date)
            HStack(spacing: 8) {
                Image(systemName: snapshot.isDemo == true ? "play.rectangle.fill"
                      : stale ? "exclamationmark.triangle.fill" : "checkmark.icloud.fill")
                    .foregroundStyle(snapshot.isDemo == true ? .blue : stale ? QuotaTheme.caution : QuotaTheme.ok)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(stale: stale))
                        .font(.footnote.weight(.semibold))
                    Text(subtitle(now: context.date, stale: stale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .glassCard(cornerRadius: 14)
            .accessibilityElement(children: .combine)
        }
    }

    private func title(stale: Bool) -> String {
        if snapshot.isDemo == true { return "데모 데이터" }
        let name = snapshot.deviceName ?? "Mac"
        return stale ? "\(name)에서 오래 응답이 없어요" : "\(name)와 동기화됨"
    }

    private func subtitle(now: Date, stale: Bool) -> String {
        if snapshot.isDemo == true { return "설정에서 끄면 내 Mac의 실제 데이터를 보여줍니다" }
        let ago = QuotaFormat.ago(snapshot.generatedAt, now: now)
        return stale ? "마지막 갱신 \(ago) · Mac이 켜져 있고 QuotaBar가 실행 중인지 확인하세요"
                     : "마지막 갱신 \(ago)"
    }
}

struct HeroCard: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let top = snapshot.items.max { $0.effectivePercent() < $1.effectivePercent() }
        let percent = top?.effectivePercent() ?? 0
        HStack(spacing: 20) {
            QuotaRing(percent: percent, lineWidth: 14) {
                VStack(spacing: 0) {
                    Text("\(Int(percent))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(QuotaTheme.levelLabel(percent: percent))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(QuotaTheme.levelColor(percent: percent))
                }
            }
            .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 6) {
                Text("가장 높은 사용률")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let top {
                    HStack(spacing: 8) {
                        ServiceMark(serviceID: top.serviceID, colorHex: top.colorHex, size: 24)
                        Text(top.service).font(.headline)
                    }
                    Text(top.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Label(QuotaFormat.resetText(top, now: context.date, withPeriod: false),
                              systemImage: "timer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .glassCard(cornerRadius: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(top.map { "\($0.service) \($0.name) \(Int(percent))퍼센트 사용, \(QuotaTheme.levelLabel(percent: percent))" } ?? "")
    }
}

struct ServiceCard: View {
    let section: ServiceSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ServiceMark(serviceID: section.first.serviceID, colorHex: section.first.colorHex, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.first.service).font(.headline)
                    if let plan = section.items.compactMap(\.planName).first {
                        Text(plan).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            ForEach(section.items) { item in
                QuotaLine(item: item)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
    }
}

struct QuotaLine: View {
    let item: WidgetQuotaItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let percent = item.effectivePercent(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.subheadline)
                    Spacer()
                    Text("\(Int(percent))%")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(QuotaTheme.levelColor(percent: percent))
                }
                QuotaBarGauge(percent: percent, height: 8)
                HStack {
                    Text(QuotaFormat.resetText(item, now: context.date))
                    Spacer()
                    if let usage = item.usageText, !usage.hasSuffix("%") {
                        Text(usage).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.syncError != nil {
                    Label("Mac에서 마지막 조회 실패: 값이 오래됐을 수 있어요", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(QuotaTheme.caution)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.name) \(Int(percent))퍼센트 사용. \(QuotaFormat.resetText(item, now: context.date))")
        }
    }
}

// MARK: - 글래스 카드

extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7))
        }
    }
}
