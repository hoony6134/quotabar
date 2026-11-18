import SwiftUI

/// 새 계정 연동 시트
struct AddAccountView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var service: ServiceKind = .claude
    @State private var label = ""
    @State private var credential = ""
    @State private var detectMessage: String?
    /// Claude: 지금 Claude Code에 로그인된 계정을 복사한 "고정된 로그인"
    @State private var capturedProfile: ClaudeProfile?
    @State private var isCapturing = false
    @State private var captureError: String?
    @State private var browserLogin: ClaudeConnector.BrowserLogin?

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
                    if let profile = capturedProfile {
                        capturedRow(profile)
                    } else {
                        if service == .claude {
                            ClaudeBrowserLoginButton(isCapturing: $isCapturing, pending: $browserLogin,
                                                     onResult: applyCapture)
                        }
                        if browserLogin == nil {
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
                        if service == .claude {
                            HStack {
                                ClaudeCaptureButton(title: "현재 Claude Code 로그인 가져오기",
                                                    isCapturing: $isCapturing,
                                                    onResult: applyCapture)
                                if !swapSlots.isEmpty {
                                    ClaudeSwapImportMenu(slots: swapSlots,
                                                         isCapturing: $isCapturing,
                                                         onResult: applyCapture)
                                }
                            }
                            if hasFollowingClaudeAccount {
                                Text("이미 '현재 로그인 따라가기' Claude 계정이 있습니다. 팀/개인을 각각 보려면 그 계정 설정에서 '현재 로그인에 고정'을 먼저 누르고, Claude Code에서 다른 계정으로 로그인한 뒤 여기서 가져오세요.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
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
                                     credential: credential.isEmpty ? nil : credential,
                                     identity: capturedProfile?.identity?.label)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCapturing || browserLogin != nil)
                .quotaGlassButton(prominent: true)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: service) { _, _ in
            credential = ""
            detectMessage = nil
            capturedProfile = nil
            captureError = nil
            browserLogin = nil
        }
    }

    /// 가져온 로그인 요약 + 지우기
    @ViewBuilder
    private func capturedRow(_ profile: ClaudeProfile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pin.fill")
                .foregroundStyle(ServiceKind.claude.brandColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.ownLineage == true ? "브라우저 로그인" : "고정된 로그인")
                    .font(.caption.bold())
                Text(profile.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if profile.identity == nil {
                    Text("계정 정보를 확인하지 못해 조직 이름 없이 저장됩니다(조회는 정상 동작).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("지우기") {
                capturedProfile = nil
                credential = ""
            }
            .quotaGlassButton()
            .controlSize(.small)
        }
        .padding(10)
        .quotaGlassSurface(cornerRadius: 10)
    }

    private var swapSlots: [ClaudeConnector.SwapSlot] { ClaudeConnector.swapSlots() }

    private func applyCapture(_ result: Result<ClaudeProfile, Error>) {
        switch result {
        case .success(let profile):
            capturedProfile = profile
            credential = profile.encodedCredential
            captureError = nil
            detectMessage = nil
            if label.isEmpty, let suggested = Self.suggestedLabel(for: profile) {
                label = suggested
            }
        case .failure(let error):
            captureError = error.localizedDescription
        }
    }

    private var hasFollowingClaudeAccount: Bool {
        store.accounts.contains { $0.service == .claude && ($0.credentialMode ?? .auto) == .auto }
    }

    private static func suggestedLabel(for profile: ClaudeProfile) -> String? {
        guard let identity = profile.identity else { return nil }
        if let org = identity.organizationName, !org.isEmpty { return org }
        if let kind = PlanDetection.claudePlan(organizationType: identity.organizationType,
                                               subscriptionType: nil, rateLimitTier: nil) { return kind }
        return nil
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
        if capturedProfile != nil {
            return "토큰 사본은 macOS 키체인에만 저장되며, 만료되면 QuotaBar가 자체적으로 갱신합니다."
        }
        if service.autoCredentialSentinel != nil {
            return "비워두거나 자동 감지를 누르면 매 갱신마다 로컬 자격증명/기록을 다시 읽습니다."
        }
        return "토큰은 macOS 키체인에만 저장됩니다."
    }
}

/// "브라우저로 로그인 (권장)" — QuotaBar 전용 로그인을 만든다. 브라우저에서 승인 후 표시되는 코드를 붙여넣는다.
struct ClaudeBrowserLoginButton: View {
    var title = "브라우저로 로그인 (권장)"
    @Binding var isCapturing: Bool
    /// 진행 중인 로그인 — 부모가 이 동안 토큰 칸을 숨겨 코드를 엉뚱한 곳에 붙여넣지 않게 한다.
    @Binding var pending: ClaudeConnector.BrowserLogin?
    let onResult: (Result<ClaudeProfile, Error>) -> Void

    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        if let pending {
            VStack(alignment: .leading, spacing: 4) {
                Text("브라우저에서 승인한 뒤 표시된 코드를 붙여넣으세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("로그인 코드", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { finish(pending) }
                    Button("확인") { finish(pending) }
                        .disabled(code.isEmpty || isCapturing)
                        .quotaGlassButton(prominent: true)
                    Button("취소") { self.pending = nil; code = "" }
                        .quotaGlassButton()
                }
            }
        } else {
            Button {
                do {
                    let login = try ClaudeConnector.startBrowserLogin()
                    pending = login
                    openURL(login.url)
                } catch {
                    onResult(.failure(error))
                }
            } label: {
                Label(title, systemImage: "safari")
            }
            .disabled(isCapturing)
            .quotaGlassButton(prominent: true)
        }
    }

    private func finish(_ login: ClaudeConnector.BrowserLogin) {
        isCapturing = true
        Task {
            let result: Result<ClaudeProfile, Error>
            do {
                result = .success(try await ClaudeConnector.finishBrowserLogin(login, pasted: code))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isCapturing = false
                if case .success = result { pending = nil; code = "" }
                onResult(result)
            }
        }
    }
}

/// "현재 Claude Code 로그인 가져오기" 버튼 — 진행 표시와 결과 콜백을 묶는다.
struct ClaudeCaptureButton: View {
    let title: String
    @Binding var isCapturing: Bool
    let onResult: (Result<ClaudeProfile, Error>) -> Void

    var body: some View {
        Button {
            isCapturing = true
            Task {
                let result: Result<ClaudeProfile, Error>
                do {
                    result = .success(try await ClaudeConnector.captureCurrentLogin())
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    isCapturing = false
                    onResult(result)
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isCapturing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "pin")
                }
                Text(isCapturing ? "로그인 확인 중…" : title)
            }
        }
        .disabled(isCapturing)
        .quotaGlassButton()
    }
}


/// cswap(claude-swap)에 저장된 계정 중 하나를 골라 고정된 로그인으로 가져오는 메뉴.
struct ClaudeSwapImportMenu: View {
    let slots: [ClaudeConnector.SwapSlot]
    @Binding var isCapturing: Bool
    let onResult: (Result<ClaudeProfile, Error>) -> Void

    var body: some View {
        Menu("cswap에서 가져오기") {
            ForEach(slots) { slot in
                Button(slot.menuLabel) {
                    isCapturing = true
                    Task {
                        let result: Result<ClaudeProfile, Error>
                        do {
                            result = .success(try await ClaudeConnector.captureSwapAccount(slot))
                        } catch {
                            result = .failure(error)
                        }
                        await MainActor.run {
                            isCapturing = false
                            onResult(result)
                        }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(isCapturing)
    }
}
