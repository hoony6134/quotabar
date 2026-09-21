import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppStore: ObservableObject {

    @Published var accounts: [Account] = [] {
        didSet { save() }
    }
    @Published var isRefreshing = false
    @Published var lastRefreshAt: Date?
    @Published var nextRefreshAt: Date?

    @AppStorage("refreshIntervalMinutes") var refreshIntervalMinutes: Int = 5 {
        didSet { restartTimer() }
    }
    @AppStorage("hideDockIcon") var hideDockIcon: Bool = false {
        didSet { applyActivationPolicy() }
    }
    @AppStorage("menuBarQuotaSelection") var menuBarQuotaSelection: String = MenuBarQuotaOption.worstID
    @AppStorage("enableResetNotifications") var enableResetNotifications: Bool = false {
        didSet { handleNotificationToggle() }
    }

    private var timer: Timer?
    private var loading = false
    private var widgetRefreshListener: WidgetRefreshListener?

    init() {
        load()
        if accounts.isEmpty {
            // 첫 실행: 자동 감지 가능한 서비스를 기본 계정으로 깔아준다
            accounts = ServiceKind.allCases.map { kind in
                Account(service: kind, label: "기본",
                        apiSyncEnabled: kind.autoCredentialSentinel != nil,
                        quotas: DefaultQuotas.quotas(for: kind))
            }
        }
        migrateAccounts()
        rolloverManualQuotas()
        restartTimer()
        applyActivationPolicy()
        observeWidgetRefreshRequests()
    }

    /// 위젯의 새로고침 버튼이 보내는 분산 알림을 받아 즉시 갱신한다.
    /// 메뉴막대 앱은 대부분 비활성 상태라, suspensionBehavior를 .deliverImmediately로
    /// 지정해야 백그라운드에서도 알림이 들어온다 (closure API는 이 옵션이 없음).
    private func observeWidgetRefreshRequests() {
        let listener = WidgetRefreshListener { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshAll()
            }
        }
        widgetRefreshListener = listener
        DistributedNotificationCenter.default().addObserver(
            listener,
            selector: #selector(WidgetRefreshListener.handleNotification(_:)),
            name: Notification.Name(QuotaWidgetShared.refreshNotificationName),
            object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    // MARK: - 요약 (메뉴막대용)

    var worstUtilization: Double {
        accounts.map(\.worstUtilization).max() ?? 0
    }

    var worstAccount: Account? {
        accounts.max(by: { $0.worstUtilization < $1.worstUtilization })
    }

    var menuBarQuotaOptions: [MenuBarQuotaOption] {
        let quotaOptions = accounts.flatMap { account in
            account.quotas.map { quota in
                MenuBarQuotaOption(
                    id: Self.menuBarQuotaID(accountID: account.id, quotaKey: quota.def.key),
                    service: account.service,
                    title: "\(account.service.displayName) · \(quota.def.name)",
                    subtitle: account.label,
                    utilization: quota.utilization,
                    resetsAt: quota.resetsAt,
                    periodLabel: quota.def.period.label
                )
            }
        }
        let worst = quotaOptions.max { $0.utilization < $1.utilization }
        var options = [
            MenuBarQuotaOption(id: MenuBarQuotaOption.worstID,
                               service: worst?.service,
                               title: "최고 사용률",
                               subtitle: "전체 계정에서 가장 높은 퍼센트",
                               utilization: worst?.utilization ?? 0,
                               resetsAt: worst?.resetsAt,
                               periodLabel: worst?.periodLabel ?? "")
        ]
        options.append(contentsOf: quotaOptions)
        return options
    }

    var selectedMenuBarQuota: MenuBarQuotaOption {
        menuBarQuotaOptions.first { $0.id == menuBarQuotaSelection }
            ?? menuBarQuotaOptions.first
            ?? MenuBarQuotaOption(id: MenuBarQuotaOption.worstID,
                                  service: nil,
                                  title: "최고 사용률",
                                  subtitle: "표시할 쿼터 없음",
                                  utilization: 0,
                                  resetsAt: nil,
                                  periodLabel: "")
    }

    static func menuBarQuotaID(accountID: UUID, quotaKey: String) -> String {
        "\(accountID.uuidString)::\(quotaKey)"
    }

    // MARK: - 계정 관리

    /// 키체인 접근 창 최소화: 세션 동안 한 번 읽은 값은 메모리에 캐시한다.
    /// ("" = 키체인에 항목 없음)
    private var credentialCache: [UUID: String] = [:]

    func addAccount(service: ServiceKind, label: String, credential: String?) {
        let trimmed = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 센티널("auto:…")은 비밀이 아니므로 키체인에 저장하지 않는다.
        let isRealToken = !trimmed.isEmpty && trimmed != service.autoCredentialSentinel
        let account = Account(service: service, label: label,
                              apiSyncEnabled: service.supportsAPISync
                                && (isRealToken || service.autoCredentialSentinel != nil),
                              quotas: DefaultQuotas.quotas(for: service))
        if isRealToken {
            Keychain.save(trimmed, for: account.id.uuidString)
            credentialCache[account.id] = trimmed
        } else {
            credentialCache[account.id] = ""
        }
        accounts.append(account)
        if account.apiSyncEnabled {
            let id = account.id
            Task { await self.refresh(accountID: id) }
        }
    }

    func removeAccount(_ account: Account) {
        // SecItemDelete는 접근 창을 띄우지 않으므로 항상 정리
        Keychain.delete(for: account.id.uuidString)
        credentialCache[account.id] = nil
        accounts.removeAll { $0.id == account.id }
    }

    func credential(for account: Account) -> String? {
        if let cached = credentialCache[account.id] {
            return cached.isEmpty ? nil : cached
        }
        let value = Keychain.load(for: account.id.uuidString) ?? ""
        credentialCache[account.id] = value
        return value.isEmpty ? nil : value
    }

    func setCredential(_ value: String, for account: Account) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 빈 값/센티널은 키체인에서 제거 — 자동 감지는 키체인 없이 동작한다.
        if trimmed.isEmpty || trimmed == account.service.autoCredentialSentinel {
            Keychain.delete(for: account.id.uuidString)
            credentialCache[account.id] = ""
        } else {
            Keychain.save(trimmed, for: account.id.uuidString)
            credentialCache[account.id] = trimmed
        }
    }

    func updateQuota(accountID: UUID, quota: QuotaItem) {
        guard let ai = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let qi = accounts[ai].quotas.firstIndex(where: { $0.def.key == quota.def.key }) {
            accounts[ai].quotas[qi] = quota
        }
    }

    func removeQuota(accountID: UUID, key: String) {
        guard let ai = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[ai].quotas.removeAll { $0.def.key == key }
    }

    // MARK: - 순서 변경 (대시보드·메뉴바·위젯 공통)
    // 모든 순서는 `accounts` / `quotas` 배열 순서 하나로 통일된다. 여기서 바꾸면
    // accounts didSet → save() 로 영속화되고, 메뉴바·위젯 스냅샷도 같은 순서를 따른다.

    /// accounts에 처음 등장한 순서대로의 서비스 목록(대시보드 섹션 순서).
    var orderedServices: [ServiceKind] {
        var seen: [ServiceKind] = []
        for account in accounts where !seen.contains(account.service) {
            seen.append(account.service)
        }
        return seen
    }

    /// 서비스 섹션 전체를 위/아래로 이동(같은 서비스 계정들은 묶여서 함께 이동).
    func moveService(_ service: ServiceKind, up: Bool) {
        var services = orderedServices
        guard let idx = services.firstIndex(of: service) else { return }
        let target = up ? idx - 1 : idx + 1
        guard services.indices.contains(target) else { return }
        services.swapAt(idx, target)
        accounts = services.flatMap { svc in accounts.filter { $0.service == svc } }
    }

    /// 같은 서비스 안에서 계정 순서를 위/아래로 이동.
    func moveAccountWithinService(id: UUID, up: Bool) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard accounts.indices.contains(target),
              accounts[target].service == accounts[idx].service else { return }
        accounts.swapAt(idx, target)
    }

    /// 계정 안에서 쿼터 행 순서를 위/아래로 이동.
    func moveQuota(accountID: UUID, key: String, up: Bool) {
        guard let ai = accounts.firstIndex(where: { $0.id == accountID }),
              let qi = accounts[ai].quotas.firstIndex(where: { $0.def.key == key }) else { return }
        let target = up ? qi - 1 : qi + 1
        guard accounts[ai].quotas.indices.contains(target) else { return }
        accounts[ai].quotas.swapAt(qi, target)
    }

    // MARK: - 레거시 로컬 상태

    /// 예전 버전에서 저장된 로컬 쿼터의 리셋 시각이 지났으면 0으로 되돌린다.
    func rolloverManualQuotas() {
        let now = Date()
        for ai in accounts.indices {
            for qi in accounts[ai].quotas.indices {
                rolloverIfNeeded(&accounts[ai].quotas[qi], now: now)
            }
        }
    }

    private func rolloverIfNeeded(_ quota: inout QuotaItem, now: Date = Date()) {
        guard !quota.def.apiSynced else { return }
        if let resetsAt = quota.resetsAt, resetsAt <= now {
            quota.state.used = 0
            quota.state.anchor = nil
            quota.state.apiResetsAt = nil
        }
    }

    // MARK: - API 동기화

    func refreshAll() async {
        isRefreshing = true
        defer {
            let now = Date()
            lastRefreshAt = now
            nextRefreshAt = now.addingTimeInterval(refreshInterval)
            isRefreshing = false
            writeExternalSnapshots()
        }
        rolloverManualQuotas()
        for account in accounts where account.apiSyncEnabled {
            await refresh(accountID: account.id)
        }
    }

    func refresh(accountID: UUID) async {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let account = accounts[index]
        guard account.apiSyncEnabled, let connector = connector(for: account.service) else { return }
        guard let credential = credentialToUse(for: account), !credential.isEmpty else {
            accounts[index].lastSyncError = ConnectorError.noCredential.errorDescription
            return
        }
        do {
            let updates = try await connector.fetch(credential: credential)
            apply(updates: updates, accountID: accountID)
        } catch {
            if let current = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[current].lastSyncError = error.localizedDescription
            }
        }
    }

    private func connector(for service: ServiceKind) -> QuotaConnector? {
        switch service {
        case .claude:  return ClaudeConnector()
        case .chatgpt: return ChatGPTConnector()
        case .googleAI: return GeminiConnector()
        case .antigravity: return AntigravityConnector()
        case .cursor:  return CursorConnector()
        case .copilot: return CopilotConnector()
        case .nvidiaNIM: return nil
        }
    }

    private func apply(updates: [QuotaUpdate], accountID: UUID) {
        guard let ai = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let now = Date()
        for update in updates {
            if let qi = accounts[ai].quotas.firstIndex(where: { $0.def.key == update.key }) {
                accounts[ai].quotas[qi].state.used = update.used
                if let cap = update.cap { accounts[ai].quotas[qi].def.cap = cap }
                accounts[ai].quotas[qi].state.apiResetsAt = update.resetsAt
                accounts[ai].quotas[qi].state.lastSynced = now
            } else {
                let def = QuotaDef(key: update.key,
                                   name: update.name ?? update.key,
                                   cap: update.cap ?? 100,
                                   unit: update.unit ?? "",
                                   period: Self.inferredPeriod(service: accounts[ai].service,
                                                               key: update.key),
                                   apiSynced: true)
                var item = QuotaItem(def: def)
                item.state.used = update.used
                item.state.apiResetsAt = update.resetsAt
                item.state.lastSynced = now
                accounts[ai].quotas.append(item)
            }
            if let planName = update.planName {
                accounts[ai].detectedPlanName = planName
            }
        }
        accounts[ai].lastSyncError = nil
        accounts[ai].lastSyncAt = now
    }

    private static func inferredPeriod(service: ServiceKind, key: String) -> ResetPeriod {
        if key == "five_hour" || key == "codex_primary" { return .rollingHours(5) }
        if key == "gemini_5h" || key == "antigravity_5h" { return .rollingHours(5) }
        if key.hasPrefix("seven_day") || key == "codex_secondary" { return .rollingDays(7) }
        if key.hasSuffix("_day") || key.contains("_day_") { return .daily }
        return .monthly(day: 1)
    }

    private func credentialToUse(for account: Account) -> String? {
        // 예전 버전이 키체인에 센티널을 저장했을 수 있으므로 센티널 값은 무시
        if let saved = credential(for: account),
           saved != account.service.autoCredentialSentinel {
            return saved
        }
        return account.service.autoCredentialSentinel
    }

    private func migrateAccounts() {
        var existingServices = Set(accounts.map(\.service))
        for service in ServiceKind.allCases where !existingServices.contains(service) {
            accounts.append(Account(service: service, label: "기본",
                                    apiSyncEnabled: service.autoCredentialSentinel != nil,
                                    quotas: DefaultQuotas.quotas(for: service)))
            existingServices.insert(service)
        }

        for ai in accounts.indices {
            let defaults = DefaultQuotas.quotas(for: accounts[ai].service)
            for item in defaults where !accounts[ai].quotas.contains(where: { $0.def.key == item.def.key }) {
                accounts[ai].quotas.append(item)
            }
            // 주의: 앱 시작 시 키체인을 읽지 않는다 (접근 창 방지).
            // 자동 감지 지원 서비스는 키체인 없이도 동기화 가능하므로 켜둔다.
            if accounts[ai].service.supportsAPISync,
               accounts[ai].service.autoCredentialSentinel != nil {
                accounts[ai].apiSyncEnabled = true
            }
        }
    }

    // MARK: - 주기적 갱신 타이머

    private func restartTimer() {
        timer?.invalidate()
        let interval = refreshInterval
        nextRefreshAt = Date().addingTimeInterval(interval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
        Task { await refreshAll() }
    }

    private var refreshInterval: TimeInterval {
        TimeInterval(max(refreshIntervalMinutes, 1)) * 60
    }

    // MARK: - Dock 아이콘

    private func applyActivationPolicy() {
        NSApp?.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    // MARK: - 영속화

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    private func load() {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([Account].self, from: data) {
            accounts = saved
        }
    }

    private func save() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(accounts) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
        writeExternalSnapshots()
    }

    private func writeExternalSnapshots() {
        WidgetSnapshotWriter.write(accounts: accounts,
                                   lastRefreshAt: lastRefreshAt,
                                   nextRefreshAt: nextRefreshAt)
        
        if enableResetNotifications {
            NotificationManager.shared.scheduleNotifications(for: accounts)
        } else {
            NotificationManager.shared.removeAllPendingNotifications()
        }
    }
    
    private func handleNotificationToggle() {
        if enableResetNotifications {
            Task {
                let granted = await NotificationManager.shared.requestAuthorization()
                if granted {
                    NotificationManager.shared.scheduleNotifications(for: accounts)
                } else {
                    Task { @MainActor in
                        self.enableResetNotifications = false
                    }
                }
            }
        } else {
            NotificationManager.shared.removeAllPendingNotifications()
        }
    }
}
