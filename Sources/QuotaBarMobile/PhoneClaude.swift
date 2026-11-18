import Foundation
import Security
import SwiftUI

/// iPhone에서 직접 로그인한 Claude 계정 — Mac 없이 iPhone이 사용량을 조회한다.
/// 토큰은 이 iPhone 키체인에만 있고 iCloud로 올라가지 않는다(Mac과 다른 별도 로그인이라 서로 토큰을 폐기시키지 않는다).
struct PhoneClaudeAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var tokens: ClaudeOAuth.Tokens
    var lastError: String?

    var itemPrefix: String { "\(WidgetSnapshot.phoneItemPrefix)\(id.uuidString)" }
}

enum PhoneClaudeStore {
    private static let service = "com.wevoid.quotabar.phone"
    private static let account = "claude-accounts"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> [PhoneClaudeAccount] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([PhoneClaudeAccount].self, from: data)) ?? []
    }

    static func save(_ accounts: [PhoneClaudeAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        // 잠금 화면에서도 백그라운드 갱신이 토큰을 읽을 수 있게 AfterFirstUnlock, 기기 밖으로는 나가지 않게 ThisDeviceOnly.
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }
}

enum PhoneClaudeFetcher {
    private static var lastRunAt: Date?

    /// 모든 iPhone 계정을 조회해 앱 그룹 파일에 저장한다(위젯도 읽는다). 30초 이내 재호출은 건너뛴다.
    static func refreshAll(force: Bool = false) async {
        if !force, let last = lastRunAt, Date().timeIntervalSince(last) < 30 { return }
        lastRunAt = Date()
        var accounts = PhoneClaudeStore.load()
        let previous = WidgetSnapshot.loadPhoneItems()
        var items: [WidgetQuotaItem] = []
        for i in accounts.indices {
            do {
                items += try await fetch(&accounts[i])
                accounts[i].lastError = nil
            } catch {
                // 실패하면 직전 값을 유지하고 오류만 표시한다.
                let message = error.localizedDescription
                accounts[i].lastError = message
                let prefix = accounts[i].itemPrefix
                items += previous.filter { $0.id.hasPrefix(prefix) }.map { var item = $0; item.syncError = message; return item }
            }
        }
        PhoneClaudeStore.save(accounts)
        WidgetSnapshot.savePhoneItems(items)
    }

    private static func fetch(_ account: inout PhoneClaudeAccount) async throws -> [WidgetQuotaItem] {
        let config = ClaudeOAuth.syncedConfig()
        if account.tokens.isExpiring {
            account.tokens = try await refresh(account.tokens, config: config)
        }
        let userAgent = ClaudeOAuth.usageUserAgent(cliVersion: config?.cliVersion)
        var (data, status, _) = try await ClaudeOAuth.get(ClaudeOAuth.usageURL, token: account.tokens.accessToken, userAgent: userAgent)
        if status == 401 || status == 403 {
            account.tokens = try await refresh(account.tokens, config: config)
            (data, status, _) = try await ClaudeOAuth.get(ClaudeOAuth.usageURL, token: account.tokens.accessToken, userAgent: userAgent)
        }
        switch status {
        case 200: break
        case 429: throw ClaudeOAuth.Failure(message: "요청이 제한됐습니다(429). 잠시 후 자동으로 다시 시도합니다.")
        default: throw ClaudeOAuth.Failure(message: "사용량 조회 실패(HTTP \(status))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeOAuth.Failure(message: "사용량 응답을 해석하지 못했습니다.")
        }
        let prefix = account.itemPrefix
        let label = account.label
        return ClaudeOAuth.parseUsageWindows(json).map { window in
            let period: (label: String, seconds: Double?) =
                window.key == "five_hour" ? ("5시간", 5 * 3600)
                : window.key == "extra_usage" ? ("월간", nil)
                : ("주간", 7 * 86400)
            return WidgetQuotaItem(id: "\(prefix)::\(window.key)", service: "Claude", label: label,
                                   name: window.name, percent: window.percent.rounded(), resetsAt: window.resetsAt,
                                   periodLabel: period.label, serviceID: "claude", colorHex: "D97857",
                                   usageText: "\(Int(window.percent.rounded()))%", windowSeconds: period.seconds)
        }
    }

    private static func refresh(_ tokens: ClaudeOAuth.Tokens, config: ClaudeOAuth.Config?) async throws -> ClaudeOAuth.Tokens {
        guard let config else {
            throw ClaudeOAuth.Failure(message: "로그인 설정이 없습니다. Mac에서 QuotaBar를 한 번 실행해 주세요.")
        }
        switch await ClaudeOAuth.refresh(tokens, config: config) {
        case .refreshed(let fresh): return fresh
        case .dead: throw ClaudeOAuth.Failure(message: "로그인이 만료됐습니다. 설정에서 다시 로그인해 주세요.")
        case .rateLimited: throw ClaudeOAuth.Failure(message: "토큰 갱신이 제한됐습니다(429). 잠시 후 다시 시도합니다.")
        case .failed(let reason): throw ClaudeOAuth.Failure(message: "토큰 갱신 실패(\(reason))")
        }
    }
}

// MARK: - 계정 목록·로그인 요청

/// 로그인 시트를 띄우는 요청. `accountID`가 있으면 그 계정(대시보드 카드의 Mac 계정 또는 기존 iPhone 계정)에 연결한다.
struct PhoneLoginRequest: Identifiable {
    let id = UUID()
    var label: String = ""
    var accountID: UUID?
}

extension MirrorModel {
    /// 추가 또는 같은 id의 계정을 교체(다시 로그인)하고 바로 조회한다.
    func savePhoneAccount(_ account: PhoneClaudeAccount) {
        var list = PhoneClaudeStore.load()
        if let i = list.firstIndex(where: { $0.id == account.id }) { list[i] = account } else { list.append(account) }
        PhoneClaudeStore.save(list)
        phoneAccounts = list
        Task { await refreshPhone(force: true) }
    }

    func removePhoneAccounts(at offsets: IndexSet) {
        var list = PhoneClaudeStore.load()
        let ids = offsets.map { phoneAccounts[$0].id }
        list.removeAll { ids.contains($0.id) }
        PhoneClaudeStore.save(list)
        phoneAccounts = list
        Task { await refreshPhone(force: true) }
    }
}

// MARK: - 설정 화면

/// 설정의 "iPhone에서 직접 조회" 섹션. 로그인 시트는 Form 행이 다시 그려져도 닫히지 않게 호출한 쪽(설정 루트)이 띄운다.
struct PhoneClaudeSection: View {
    @EnvironmentObject var model: MirrorModel
    let onAdd: () -> Void

    var body: some View {
        Section {
            ForEach(model.phoneAccounts) { account in
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                    if let error = account.lastError {
                        Text(error).font(.caption).foregroundStyle(QuotaTheme.caution)
                    }
                }
            }
            .onDelete { model.removePhoneAccounts(at: $0) }
            Button(action: onAdd) {
                Label("Claude 계정 추가 (브라우저로 로그인)", systemImage: "safari")
            }
        } header: {
            Text("iPhone에서 직접 조회")
        } footer: {
            Text("Mac 없이 이 iPhone이 Claude 사용량을 직접 가져옵니다. 대시보드의 Claude 카드에서 'iPhone에서 연결'을 눌러도 됩니다. Mac과 별도 로그인이라 서로 영향을 주지 않으며, 토큰은 이 iPhone 키체인에만 저장됩니다. 약 한 달마다 다시 로그인해야 합니다.")
        }
    }
}

struct PhoneClaudeLoginView: View {
    let request: PhoneLoginRequest

    @EnvironmentObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var label = ""
    @State private var pending: ClaudeOAuth.PendingLogin?
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("라벨 (비우면 조직 이름)", text: $label)
                }
                Section {
                    Button("1. 브라우저에서 로그인") { start() }
                    TextField("2. 표시된 코드 붙여넣기", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(pending == nil)
                    Button {
                        finish()
                    } label: {
                        if isWorking { ProgressView() } else { Text("3. 완료") }
                    }
                    .disabled(pending == nil || code.isEmpty || isWorking)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(QuotaTheme.caution)
                    } else {
                        Text("Safari에서 원하는 계정으로 로그인·승인하면 코드가 나옵니다. 복사해서 돌아와 붙여넣으세요.")
                    }
                }
            }
            .navigationTitle(request.accountID == nil ? "Claude 계정 추가" : "iPhone에서 연결")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if label.isEmpty { label = request.label } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
            }
        }
    }

    private func start() {
        guard let config = ClaudeOAuth.syncedConfig() else {
            error = "로그인 설정이 아직 없습니다. Mac에서 QuotaBar(그리고 Claude Code)를 한 번 실행하면 iCloud로 전달됩니다."
            return
        }
        do {
            let login = try ClaudeOAuth.startLogin(config: config)
            pending = login
            error = nil
            openURL(login.url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func finish() {
        guard let pending else { return }
        isWorking = true
        Task {
            do {
                let tokens = try await ClaudeOAuth.exchange(pending, pasted: code)
                var name = label.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    name = await ClaudeOAuth.profileLabel(
                        token: tokens.accessToken,
                        userAgent: ClaudeOAuth.usageUserAgent(cliVersion: pending.config.cliVersion)) ?? "Claude"
                }
                model.savePhoneAccount(PhoneClaudeAccount(id: request.accountID ?? UUID(), label: name, tokens: tokens))
                dismiss()
            } catch {
                self.error = error.localizedDescription
                // 코드는 한 번만 쓸 수 있으니 실패하면 처음부터 다시
                self.pending = nil
                code = ""
            }
            isWorking = false
        }
    }
}
