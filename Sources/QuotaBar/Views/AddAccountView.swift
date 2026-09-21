import SwiftUI

/// 새 계정 연동 시트
struct AddAccountView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var service: ServiceKind = .claude
    @State private var label = ""
    @State private var credential = ""
    @State private var detectMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("계정 추가")
                .font(.title2.bold())

            Picker("서비스", selection: $service) {
                ForEach(ServiceKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            TextField("라벨 (예: 개인, 회사)", text: $label)
                .textFieldStyle(.roundedBorder)

            if service.supportsAPISync {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField(tokenPlaceholder, text: $credential)
                            .textFieldStyle(.roundedBorder)
                        if let sentinel = service.autoCredentialSentinel {
                            Button("자동 감지") {
                                credential = sentinel
                                detectMessage = "\(service.displayName) 자동 감지를 사용합니다."
                            }
                            .quotaGlassButton()
                        }
                    }
                    if let detectMessage {
                        Text(detectMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(service.authHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(helperText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(service.authHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("취소") { dismiss() }
                    .quotaGlassButton()
                Spacer()
                Button("추가") {
                    let name = label.isEmpty ? "계정 \(count + 1)" : label
                    store.addAccount(service: service, label: name,
                                     credential: credential.isEmpty ? nil : credential)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .quotaGlassButton(prominent: true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: service) { _, _ in
            credential = ""
            detectMessage = nil
        }
    }

    private var count: Int {
        store.accounts.filter { $0.service == service }.count
    }

    private var tokenPlaceholder: String {
        switch service {
        case .claude:  return "OAuth 액세스 토큰 (비우면 자동 감지)"
        case .chatgpt: return "Codex 액세스 토큰 (비우면 자동 감지)"
        case .googleAI, .antigravity: return "비워두면 로컬 기록 자동 감지"
        case .cursor:  return "WorkosCursorSessionToken 쿠키 값"
        case .copilot: return "GitHub Personal Access Token"
        default:       return "토큰"
        }
    }

    private var helperText: String {
        if service.autoCredentialSentinel != nil {
            return "비워두거나 자동 감지를 누르면 매 갱신마다 로컬 자격증명/기록을 다시 읽습니다."
        }
        return "토큰은 macOS 키체인에만 저장됩니다."
    }
}
