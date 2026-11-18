import CryptoKit
import Foundation

/// Claude 로그인(Claude Code와 같은 PKCE 흐름)·토큰 갱신·사용량 조회 — Mac 앱과 iPhone 앱이 함께 쓴다.
///
/// OAuth 설정(클라이언트 ID·엔드포인트)은 하드코딩하지 않는다. Mac이 설치된 Claude Code에서 읽어
/// iCloud 키-값 저장소로 올리고, Claude Code가 없는 iPhone은 그 값을 받아 쓴다. 토큰은 올리지 않는다.
enum ClaudeOAuth {
    struct Config: Codable, Equatable {
        var clientID: String
        var authorizeURL: URL
        var tokenURL: URL
        var redirectURL: String
        /// 사용량 API의 User-Agent에 쓰는 Claude Code 버전 (iPhone은 Mac이 감지한 값을 쓴다)
        var cliVersion: String?
    }

    struct Tokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?

        var isExpiring: Bool { (expiresAt ?? .distantFuture) <= Date().addingTimeInterval(60) }
    }

    struct PendingLogin {
        let verifier: String
        let state: String
        let url: URL
        let config: Config
    }

    struct UsageWindow {
        var key: String
        var name: String
        var percent: Double
        var resetsAt: Date?
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum RefreshResult {
        case refreshed(Tokens)
        /// 서버가 grant를 거부(`invalid_grant`) — 다시 로그인해야 한다
        case dead
        case rateLimited
        case failed(String)
    }

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// 토큰 엔드포인트용 UA. 서버가 "anthropic"·"claude-code/…" UA는 바로 429로 막으므로 앱 이름·버전을 밝힌다.
    static let tokenUserAgent =
        "QuotaBar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"

    // MARK: - 설정 (Claude Code 번들에서 감지 → iCloud로 공유)

    /// 번들 안의 운영 설정 객체 `{BASE_API_URL:"https://api.anthropic.com",…,CLIENT_ID:"…"}` 텍스트에서 값을 뽑는다.
    static func parseConfig(_ text: String) -> Config? {
        // 앞에 `,`/`{`를 요구해 DESIGN_CLIENT_ID 같은 다른 키와 섞이지 않게 한다.
        func value(_ key: String) -> String? {
            guard let r = text.range(of: #"[,{]\#(key):"([^"]+)""#, options: .regularExpression) else { return nil }
            let match = text[r]
            guard let q = match.firstIndex(of: "\"") else { return nil }
            return String(match[match.index(after: q)..<match.index(before: match.endIndex)])
        }
        guard let clientID = value("CLIENT_ID"),
              let authorize = value("CLAUDE_AI_AUTHORIZE_URL").flatMap(URL.init(string:)),
              let token = value("TOKEN_URL").flatMap(URL.init(string:)),
              let redirect = value("MANUAL_REDIRECT_URL") else { return nil }
        return Config(clientID: clientID, authorizeURL: authorize, tokenURL: token, redirectURL: redirect)
    }

    private static let kvsConfigKey = "quotabar.claudeOAuthConfig.v1"

    /// Mac이 감지한 설정을 iCloud에 올린다(값이 바뀔 때만).
    static func publish(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        let store = NSUbiquitousKeyValueStore.default
        guard store.data(forKey: kvsConfigKey) != data else { return }
        store.set(data, forKey: kvsConfigKey)
        store.synchronize()
    }

    /// iCloud로 받은 설정 (Mac에서 QuotaBar를 한 번이라도 실행했어야 있다).
    static func syncedConfig() -> Config? {
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: kvsConfigKey) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: - 브라우저 로그인 (PKCE, 코드 붙여넣기)

    static func startLogin(config: Config) throws -> PendingLogin {
        guard var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw Failure(message: "로그인 주소를 만들지 못했습니다.")
        }
        let verifier = randomURLSafe()
        let state = randomURLSafe()
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURL),
            URLQueryItem(name: "scope", value: "user:profile user:inference user:sessions:claude_code"),
            URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw Failure(message: "로그인 주소를 만들지 못했습니다.") }
        return PendingLogin(verifier: verifier, state: state, url: url, config: config)
    }

    /// 브라우저 콜백 페이지에 표시된 코드(`code#state`)를 토큰으로 교환한다.
    static func exchange(_ login: PendingLogin, pasted: String) async throws -> Tokens {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard let code = parts.first.map(String.init), !code.isEmpty else {
            throw Failure(message: "브라우저에 표시된 코드를 붙여넣으세요.")
        }
        if parts.count == 2, String(parts[1]) != login.state {
            throw Failure(message: "다른 로그인 시도의 코드입니다. '브라우저로 로그인'을 다시 눌러 주세요.")
        }
        let (data, status) = try await postToken(login.config.tokenURL, body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": login.config.redirectURL,
            "client_id": login.config.clientID,
            "code_verifier": login.verifier,
            "state": login.state,
        ])
        if status == 429 {
            throw Failure(message: "로그인 요청이 제한됐습니다(429). 잠시 후 '브라우저로 로그인'을 다시 눌러 주세요.")
        }
        guard status == 200, let tokens = tokens(from: data, previous: nil) else {
            throw Failure(message: "로그인 코드가 거부됐습니다(HTTP \(status)). 코드는 한 번만 쓸 수 있으니 '브라우저로 로그인'을 다시 눌러 주세요.")
        }
        return tokens
    }

    // MARK: - 토큰 갱신

    static func refresh(_ tokens: Tokens, config: Config) async -> RefreshResult {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { return .dead }
        guard let (data, status) = try? await postToken(config.tokenURL, body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]) else { return .failed("네트워크 오류") }
        if status == 200, let fresh = self.tokens(from: data, previous: tokens) { return .refreshed(fresh) }
        if status == 429 { return .rateLimited }
        // RFC 6749: grant 자체가 거부됐을 때만 죽은 로그인으로 본다.
        if isInvalidGrant(data) { return .dead }
        return .failed("HTTP \(status)")
    }

    static func isInvalidGrant(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String == "invalid_grant"
    }

    // MARK: - 사용량

    static func usageUserAgent(cliVersion: String?) -> String {
        "claude-code/\(cliVersion ?? "2.0.0")"
    }

    static func get(_ url: URL, token: String, userAgent: String) async throws -> (Data, Int, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http)
    }

    /// 사용량 응답에서 표시할 윈도우만 뽑는다 (응답에 있는 것만 — 플랜에 따라 없는 윈도우가 있다).
    static func parseUsageWindows(_ json: [String: Any]) -> [UsageWindow] {
        // Opus 별도 주간 한도는 폐지돼 표시하지 않는다(레거시 seven_day_opus는 읽지 않음).
        let fixed: [(key: String, name: String)] = [
            ("five_hour", "세션 (5시간)"),
            ("seven_day", "주간 (전체 모델)"),
            ("seven_day_sonnet", "주간 (Sonnet)"),
            ("seven_day_routines", "주간 (루틴)"),
            ("seven_day_cowork", "주간 (Cowork)"),
        ]
        var windows: [UsageWindow] = []
        for window in fixed {
            guard let obj = json[window.key] as? [String: Any],
                  let utilization = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(key: window.key, name: window.name, percent: utilization,
                                       resetsAt: iso8601(obj["resets_at"] as? String)))
        }
        // 모델 한정 주간 한도 — limits[] = { kind: "weekly_scoped", percent, resets_at, scope: { model: { display_name } } }
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
                let scope = limit["scope"] as? [String: Any]
                let display = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? (scope?["display_name"] as? String)
                    ?? (scope?["name"] as? String)
                guard let display, let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                let slug = display.lowercased()
                    .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                let key = "seven_day_\(slug)"
                guard !slug.isEmpty, !slug.contains("opus"),
                      !windows.contains(where: { $0.key == key }) else { continue }
                windows.append(UsageWindow(key: key, name: "주간 (\(display))", percent: percent,
                                           resetsAt: iso8601(limit["resets_at"] as? String)))
            }
        }
        // 추가 사용량(Extra usage) — 월 한도 대비 사용률
        if let extra = json["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) ?? true,
           let utilization = (extra["utilization"] as? NSNumber)?.doubleValue {
            windows.append(UsageWindow(key: "extra_usage", name: "추가 사용량 (월)", percent: utilization, resetsAt: nil))
        }
        return windows
    }

    /// `/api/oauth/profile`에서 기본 라벨로 쓸 조직 이름(없으면 이메일).
    static func profileLabel(token: String, userAgent: String) async -> String? {
        guard let (data, status, _) = try? await get(profileURL, token: token, userAgent: userAgent), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let org = (json["organization"] as? [String: Any])?["name"] as? String
        let email = (json["account"] as? [String: Any])?["email"] as? String
        return [org, email].compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: - 공용 헬퍼

    static func expiry(from json: [String: Any]) -> Date? {
        if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 {
            return Date().addingTimeInterval(expiresIn)
        }
        if let value = (json["expires_at"] as? NSNumber)?.doubleValue, value > 0 {
            // ms 또는 s 모두 허용.
            return Date(timeIntervalSince1970: value > 1_000_000_000_000 ? value / 1000 : value)
        }
        if let ms = (json["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }

    static func iso8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func tokens(from data: Data, previous: Tokens?) -> Tokens? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        // refresh token은 회전될 수 있다 — 새 값이 오면 교체, 없으면 기존 유지.
        return Tokens(accessToken: access,
                      refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
                      expiresAt: expiry(from: json) ?? previous?.expiresAt)
    }

    private static func postToken(_ url: URL, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(tokenUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func randomURLSafe() -> String {
        base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
