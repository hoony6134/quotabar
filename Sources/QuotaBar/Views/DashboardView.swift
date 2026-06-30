import SwiftUI

/// 메인 윈도우 대시보드: 서비스별 섹션 → 계정 카드 → 쿼터 행
struct DashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddAccount = false

    private var grouped: [(service: ServiceKind, accounts: [Account])] {
        // 사용자가 지정한 순서(orderedServices)를 따른다.
        store.orderedServices.compactMap { kind in
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
                serviceReorderControls(service)
            }
            ForEach(accounts) { account in
                AccountCard(account: account)
            }
        }
    }

    /// 서비스 섹션을 위/아래로 옮기는 컨트롤(맨 위/아래면 비활성).
    @ViewBuilder
    private func serviceReorderControls(_ service: ServiceKind) -> some View {
        let services = store.orderedServices
        HStack(spacing: 2) {
            Button { store.moveService(service, up: true) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(services.first == service)
            Button { store.moveService(service, up: false) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(services.last == service)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help("이 서비스의 표시 순서를 위/아래로 이동")
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
                accountReorderControls
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

            ForEach(Array(account.quotas.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    QuotaRow(accountID: account.id, item: item)
                    quotaReorderControls(index: index, key: item.def.key)
                }
            }
        }
        .padding(14)
        .quotaGlassSurface(cornerRadius: 12, interactive: true)
    }

    /// 같은 서비스에 계정이 2개 이상일 때만 계정 순서 이동 컨트롤을 보여준다.
    @ViewBuilder
    private var accountReorderControls: some View {
        let siblings = store.accounts.filter { $0.service == account.service }
        if siblings.count > 1 {
            HStack(spacing: 2) {
                Button { store.moveAccountWithinService(id: account.id, up: true) } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(siblings.first?.id == account.id)
                Button { store.moveAccountWithinService(id: account.id, up: false) } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(siblings.last?.id == account.id)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help("같은 서비스 안에서 계정 순서 이동")
        }
    }

    /// 쿼터 행을 위/아래로 옮기는 컨트롤(맨 위/아래면 비활성).
    @ViewBuilder
    private func quotaReorderControls(index: Int, key: String) -> some View {
        VStack(spacing: 0) {
            Button { store.moveQuota(accountID: account.id, key: key, up: true) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            Button { store.moveQuota(accountID: account.id, key: key, up: false) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= account.quotas.count - 1)
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .foregroundStyle(.tertiary)
    }
}
