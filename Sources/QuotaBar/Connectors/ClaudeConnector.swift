import Foundation
import LocalAuthentication
import Security

/// Claude (Pro/Max) — Claude Code가 쓰는 OAuth usage 엔드포인트에서
/// 5시간 세션 / 7일 / 7일(Opus) 사용률(%)을 가져온다. 비공식 엔드포인트.
///
/// 인증 모드 두 가지:
    /// 1. `auto:claude-code` 센티널 — 매 갱신마다 Claude Code 파일 자격증명을
    ///    실시간으로 다시 읽는다. Claude Code가 토큰을 갱신하면 그대로 따라간다. (권장)
/// 2. 직접 붙여넣은 액세스 토큰 — 만료되면 401이 난다.
struct ClaudeConnector: QuotaConnector {
    static let autoSentinel = "auto:claude-code"
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
    }

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let auto = credential == Self.autoSentinel
        let token = try Self.token(from: credential)
        let result = try await Self.fetchUsage(token: token)

        switch result.code {
        case 200:
            return try Self.parseUsage(result.data)
        case 401 where auto, 403 where auto:
            let freshToken = try Self.token(from: Self.autoSentinel, forceDetect: true)
            let retry = try await Self.fetchUsage(token: freshToken)
            guard retry.code == 200 else {
                throw ConnectorError.hint("인증 실패(\(retry.code)). Claude Code 자격증명을 다시 감지했지만 사용량 조회가 거부됐습니다. Claude Code를 한 번 실행해 로그인 상태를 갱신하세요.")
            }
            return try Self.parseUsage(retry.data)
        case 401, 403:
            throw ConnectorError.hint("인증 실패(\(result.code)). 토큰이 만료된 것 같습니다. 계정 설정에서 '자동 감지 사용'을 누르면 Claude Code 자격증명을 매번 다시 읽습니다.")
        case 429:
            throw ConnectorError.rateLimited
        default:
            throw ConnectorError.network("HTTP \(result.code)")
        }
    }

    private static func token(from credential: String, forceDetect: Bool = false) throws -> String {
        if credential == Self.autoSentinel {
            guard let creds = Self.detectClaudeCodeCredentials(force: forceDetect) else {
                throw ConnectorError.hint("Claude Code 자격증명을 찾지 못했습니다. Claude Code에 로그인돼 있는지 확인하세요.")
            }
            if let expiresAt = creds.expiresAt, expiresAt <= Date() {
                throw ConnectorError.hint("Claude Code 토큰이 만료됐습니다. Claude Code를 한 번 실행하면 자동 갱신됩니다.")
            }
            return creds.accessToken
        }
        return credential
    }

    private static func fetchUsage(token: String) async throws -> (data: Data, code: Int) {
        try await HTTP.get(Self.url, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            // User-Agent가 없으면 공격적으로 429가 떨어진다
            "User-Agent": "claude-code/2.0.0",
            "Accept": "application/json",
        ])
    }

    private static func parseUsage(_ data: Data) throws -> [QuotaUpdate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.schemaChanged("JSON 아님")
        }

        var updates: [QuotaUpdate] = []
        let windows: [(key: String, name: String)] = [
            ("five_hour", "세션 (5시간)"),
            ("seven_day", "주간 (전체 모델)"),
            ("seven_day_opus", "주간 (Opus)"),
            ("seven_day_sonnet", "주간 (Sonnet)"),
        ]

        for window in windows {
            guard let obj = json[window.key] as? [String: Any] else { continue }
            let utilization = (obj["utilization"] as? NSNumber)?.doubleValue ?? 0
            let resetsAt = DateParsing.iso8601(obj["resets_at"] as? String)
            updates.append(QuotaUpdate(key: window.key, name: window.name,
                                       used: utilization, cap: 100, unit: "%",
                                       resetsAt: resetsAt,
                                       planName: PlanDetection.from(json: json)))
        }

        guard !updates.isEmpty else {
            throw ConnectorError.schemaChanged("five_hour/seven_day 필드 없음")
        }
        return updates
    }

    // MARK: - Claude Code 자격증명 감지

    /// ~/.claude/.credentials.json 등을 먼저 읽고, 없으면 키체인을 UI 없이 조회한다.
    /// 키체인 접근이 허용되지 않은 항목은 확인 창을 띄우지 않고 건너뛴다.
    /// 결과는 10분간 메모리에 캐시한다.
    private static var cachedCredentials: (value: Credentials, fetchedAt: Date)?

    static func detectClaudeCodeCredentials(force: Bool = false) -> Credentials? {
        if !force, let cached = cachedCredentials,
           Date().timeIntervalSince(cached.fetchedAt) < 600,
           (cached.value.expiresAt ?? .distantFuture) > Date() {
            return cached.value
        }
        let creds = credentialsFromFiles() ?? credentialsFromKeychainWithoutPrompt()
        if let creds { cachedCredentials = (creds, Date()) }
        return creds
    }

    private static func credentialsFromFiles() -> Credentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".config/claude/credentials.json"),
        ]
        for path in files {
            if let raw = try? String(contentsOf: path, encoding: .utf8),
               let creds = parse(credentialJSON: raw),
               (creds.expiresAt ?? .distantFuture) > Date() {
                return creds
            }
        }
        return nil
    }

    private static func credentialsFromKeychainWithoutPrompt() -> Credentials? {
        let services = [
            "Claude Code-credentials",
            "Claude Code",
            "claude-code",
        ]
        for service in services {
            if let raw = runSecurityCLI(service: service),
               let creds = parse(credentialJSON: raw),
               (creds.expiresAt ?? .distantFuture) > Date() {
                return creds
            }
        }
        return nil
    }

    private static func runSecurityCLI(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        } catch {
            // ignore
        }
        return nil
    }

    private static func parse(credentialJSON raw: String) -> Credentials? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let token = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String),
              !token.isEmpty
        else { return nil }
        var expiresAt: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let seconds = (oauth["expires_at"] as? NSNumber)?.doubleValue, seconds > 0 {
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }
}
