import SwiftUI

/// 계정 설정 팝오버: 라벨/토큰 변경, 쿼터 한도 편집, 계정 삭제
struct AccountSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var label: String = ""
    @State private var credential: String = ""
    @State private var caps: [String: String] = [:]
    /// Claude: 새로 고정한 로그인 (저장을 눌러야 반영)
    @State private var capturedProfile: ClaudeProfile?
    @State private var isCapturing = false
    @State private var captureError: String?
    @State private var confirmDelete = false

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
                credentialSection
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
                    confirmDelete = true
                } label: {
                    Label("계정 삭제", systemImage: "trash")
                }
                .quotaGlassButton()
                .confirmationDialog("'\(account.label)' 계정을 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("삭제", role: .destructive) {
                        store.removeAccount(account)
                        dismiss()
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("저장된 토큰과 한도 설정이 함께 삭제됩니다.")
                }
                Spacer()
                Button("저장") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCapturing)
                .quotaGlassButton(prominent: true)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            label = account.label
            for item in account.quotas {
                caps[item.def.key] = Fmt.quantity(item.def.cap, unit: "")
            }
        }
    }

    // MARK: - 자격증명

    @ViewBuilder
    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 현재 방식
            HStack(spacing: 6) {
                Image(systemName: modeSymbol)
                    .foregroundStyle(.secondary)
                Text(currentModeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let profile = capturedProfile {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(ServiceKind.claude.brandColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("저장하면 이 로그인으로 고정됩니다")
                            .font(.caption.bold())
                        Text(profile.displayLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("취소") {
                        capturedProfile = nil
                        credential = ""
                    }
                    .quotaGlassButton()
                    .controlSize(.small)
                }
                .padding(8)
                .quotaGlassSurface(cornerRadius: 8)
            } else {
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
                if account.service == .claude {
                    ClaudeCaptureButton(title: "현재 로그인에 고정", isCapturing: $isCapturing) { result in
                        switch result {
                        case .success(let profile):
                            capturedProfile = profile
                            credential = profile.encodedCredential
                            captureError = nil
                        case .failure(let error):
                            captureError = error.localizedDescription
                        }
                    }
                }
            }
            if let captureError {
                Label(captureError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(account.service.authHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentModeText: String {
        let mode = account.credentialMode ?? .auto
        if credential == account.service.autoCredentialSentinel, capturedProfile == nil {
            return "저장하면 '현재 로그인 따라가기'로 바뀝니다"
        }
        var text = "연결 방식: \(mode.label)"
        if let identity = account.detectedIdentity, !identity.isEmpty {
            text += " · \(identity)"
        }
        return text
    }

    private var modeSymbol: String {
        switch account.credentialMode ?? .auto {
        case .auto:       return "arrow.triangle.2.circlepath"
        case .pinned:     return "pin.fill"
        case .token:      return "key.fill"
        case .webSession: return "globe"
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
        // 자격증명은 사용자가 실제로 바꿨을 때만 저장한다 — 비워둔 채 저장해도 기존 토큰/고정 로그인이 지워지지 않는다.
        if !credential.isEmpty {
            store.setCredential(credential, for: account, identity: capturedProfile?.identity?.label)
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
