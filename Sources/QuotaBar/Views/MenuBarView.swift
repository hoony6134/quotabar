import SwiftUI
import AppKit

/// 메뉴막대 팝오버: 모든 계정의 쿼터를 컴팩트하게 보여준다
struct MenuBarView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsAction

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("QuotaBar")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .quotaGlassButton()
                .controlSize(.small)
                .disabled(store.isRefreshing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("메뉴막대 표시")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("메뉴막대 표시", selection: $store.menuBarQuotaSelection) {
                    ForEach(store.menuBarQuotaOptions) { option in
                        Label {
                            Text("\(option.title) · \(option.percentage)%")
                        } icon: {
                            Image(systemName: option.service?.symbolName ?? "gauge.with.dots.needle.67percent")
                        }
                        .tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)

                selectedQuotaSummary

                let selected = store.selectedMenuBarQuota
                QuotaResetSummary(resetsAt: selected.resetsAt,
                                  periodLabel: selected.periodLabel,
                                  compact: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.accounts.isEmpty {
                        Text("표시할 계정이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(store.accounts) { account in
                            accountBlock(account)
                        }
                    }
                }
                .padding(14)
            }
            .frame(minHeight: 260, maxHeight: .infinity)

            Divider()

            HStack {
                Button("대시보드 열기") { openDashboard() }
                .quotaGlassButton(prominent: true)
                .controlSize(.small)
                Spacer()
                Button("설정") { openSettings() }
                .quotaGlassButton()
                .controlSize(.small)
                Button("종료") {
                    NSApp.terminate(nil)
                }
                .quotaGlassButton()
                .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360, height: 560)
    }

    /// 대시보드 창을 확실히 앞으로 가져온다.
    /// MenuBarExtra(.window) 팝오버에서 openWindow만 호출하면 창이 뒤에 열리거나
    /// 포커스를 못 받는 경우가 있어, 앱 활성화 + 창 makeKeyAndOrderFront를 함께 처리한다.
    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let win = NSApp.windows.first(where: {
                ($0.identifier?.rawValue ?? "").contains("dashboard")
            }) {
                win.makeKeyAndOrderFront(nil)
                win.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 설정 창 열기. SettingsLink는 메뉴막대 앱에서 첫 클릭에 안 열리는 경우가 잦아
    /// 앱 활성화 후 Settings 씬을 직접 호출한다(macOS 14+).
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title.contains("설정") || $0.title.localizedCaseInsensitiveContains("settings") })?
                .makeKeyAndOrderFront(nil)
        }
    }

    private var selectedQuotaSummary: some View {
        let selected = store.selectedMenuBarQuota
        return HStack(spacing: 6) {
            Circle()
                .fill(UtilizationLevel.color(selected.utilization))
                .frame(width: 7, height: 7)
            Text(selected.title)
                .font(.caption2)
                .lineLimit(1)
            Spacer()
            Text("\(selected.percentage)%")
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(UtilizationLevel.color(selected.utilization))
        }
    }

    @ViewBuilder
    private func accountBlock(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ServiceBadge(service: account.service, size: 18)
                Text(account.service.displayName)
                    .font(.caption.bold())
                Text(account.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(UtilizationLevel.color(account.worstUtilization))
                    .frame(width: 8, height: 8)
                Text("\(Int(account.worstUtilization * 100))%")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(UtilizationLevel.color(account.worstUtilization))
            }
            ForEach(account.quotas) { item in
                QuotaRow(accountID: account.id, item: item, compact: true)
            }
        }
        .padding(10)
        .quotaGlassSurface(cornerRadius: 10)
    }
}

/// 메뉴막대 아이콘 + 선택한 쿼터 퍼센트 라벨
struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        // 메뉴막대 라벨은 텍스트/이미지만 지원
        let selected = store.selectedMenuBarQuota
        HStack(spacing: 7) {
            if let service = selected.service,
               let logo = ServiceLogo.templateImage(for: service) {
                // 실제 제품 로고 (템플릿 모드 — 메뉴막대 색상에 자동 적응)
                // 크기는 NSImage.size(15pt)로 지정됨 — 메뉴막대 라벨은 frame을 무시한다
                Image(nsImage: logo)
                    .renderingMode(.template)
            } else {
                Image(systemName: selected.service?.symbolName ?? symbol(for: selected.utilization))
            }
            Text("\(selected.percentage)%")
                .monospacedDigit()
        }
        .help("\(selected.title) · \(selected.percentage)%")
    }

    private func symbol(for utilization: Double) -> String {
        switch utilization {
        case ..<0.5:  return "gauge.with.dots.needle.0percent"
        case ..<0.75: return "gauge.with.dots.needle.33percent"
        case ..<0.9:  return "gauge.with.dots.needle.67percent"
        default:      return "gauge.with.dots.needle.100percent"
        }
    }
}
