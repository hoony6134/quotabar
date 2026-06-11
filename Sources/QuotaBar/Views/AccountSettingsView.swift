import SwiftUI

/// 계정 설정 팝오버: 라벨/토큰 변경, 쿼터 한도 편집, 계정 삭제
struct AccountSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var label: String = ""
    @State private var credential: String = ""
    @State private var caps: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ServiceBadge(service: account.service, size: 22)
                Text("\(account.service.displayName) · \(account.label)")
                    .font(.headline)
            }

            TextField("라벨", text: $label)
                .textFieldStyle(.roundedBorder)

            if account.service.supportsAPISync {
                HStack {
                    SecureField("토큰 (변경할 때만 입력)", text: $credential)
                        .textFieldStyle(.roundedBorder)
                    if let sentinel = account.service.autoCredentialSentinel {
                        Button("자동 감지 사용") {
                            credential = sentinel
                        }
                        .quotaGlassButton()
                    }
                }
                Text(account.service.authHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("한도 편집")
                .font(.subheadline.bold())
            ForEach(account.quotas) { item in
                HStack {
                    Text(item.def.name)
                        .font(.caption)
                    Spacer()
                    TextField("한도", text: capBinding(item.def.key))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text(item.def.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                }
            }

            Divider()
            HStack {
                Button(role: .destructive) {
                    store.removeAccount(account)
                    dismiss()
                } label: {
                    Label("계정 삭제", systemImage: "trash")
                }
                .quotaGlassButton()
                Spacer()
                Button("저장") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .quotaGlassButton(prominent: true)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            label = account.label
            for item in account.quotas {
                caps[item.def.key] = Fmt.quantity(item.def.cap, unit: "")
            }
        }
    }

    private func capBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { caps[key] ?? "" },
            set: { caps[key] = $0 }
        )
    }

    private func save() {
        guard let index = store.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        store.accounts[index].label = label
        if !credential.isEmpty || account.service.autoCredentialSentinel != nil {
            store.setCredential(credential, for: account)
            store.accounts[index].apiSyncEnabled = account.service.supportsAPISync
        }
        for item in store.accounts[index].quotas {
            if let text = caps[item.def.key], let value = Double(text), value > 0 {
                var updated = item
                updated.def.cap = value
                store.updateQuota(accountID: account.id, quota: updated)
            }
        }
        if store.accounts[index].apiSyncEnabled {
            let id = account.id
            Task { await store.refresh(accountID: id) }
        }
    }
}
