import SwiftUI

/// 메인 윈도우 대시보드: 서비스별 섹션 → 계정 카드 → 쿼터 행
struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddAccount = false

    private var grouped: [(service: ServiceKind, accounts: [Account])] {
        ServiceKind.allCases.compactMap { kind in
            let list = store.accounts.filter { $0.service == kind }
            return list.isEmpty ? nil : (kind, list)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(grouped, id: \.service) { group in
                    sectionView(group.service, group.accounts)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("QuotaBar")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddAccount = true
                } label: {
                    Label("계정 추가", systemImage: "plus")
                }
                .quotaGlassButton(prominent: true)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .quotaGlassButton()
            }
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountView()
        }
    }

    @ViewBuilder
    private func sectionView(_ service: ServiceKind, _ accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ServiceBadge(service: service)
                Text(service.displayName)
                    .font(.title3.bold())
                Text(service.planName)
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(service.brandColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(service.brandColor)
                Spacer()
            }
            ForEach(accounts) { account in
                AccountCard(account: account)
            }
        }
    }
}

// MARK: - 계정 카드

struct AccountCard: View {
    @EnvironmentObject var store: AppStore
    let account: Account
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(account.label)
                    .font(.subheadline.bold())
                if let planName = account.detectedPlanName {
                    Text(planName)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(account.service.brandColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(account.service.brandColor)
                }
                if account.apiSyncEnabled {
                    if let at = account.lastSyncAt {
                        Text("동기화 \(at.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("자동 감지 없음")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showSettings) {
                    AccountSettingsView(account: account)
                }
            }

            if let error = account.lastSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            ForEach(account.quotas) { item in
                QuotaRow(accountID: account.id, item: item)
            }
        }
        .padding(14)
        .quotaGlassSurface(cornerRadius: 12, interactive: true)
    }
}
