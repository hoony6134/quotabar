import Foundation
import LocalAuthentication
import Security

/// Claude (Pro/Max) — Claude Code가 쓰는 OAuth usage 엔드포인트에서
/// 5시간 세션 / 7일 / 7일(Opus) 사용률(%)을 가져온다. 비공식 엔드포인트.
///
/// 인증 모드 두 가지:
/// 1. `auto:claude-code` 센티널 — 매 갱신마다 Claude Code 자격증명을 실시간으로
///    다시 읽는다. 토큰이 만료된 것 같으면 **하이브리드로 재발급**한다:
///      (1) 저장된 refresh token으로 OAuth 토큰을 직접 갱신 (빠르고 쿼터 소모 없음)
///      (2) 실패하면 `claude` CLI를 한 번 실행해 Claude Code가 직접 갱신하게 함
///    재발급에 성공하면 회전된 토큰을 원본(파일/키체인)에 다시 써서 Claude Code와
///    동기화한다. (권장)
/// 2. 직접 붙여넣은 액세스 토큰 — 만료되면 401이 난다.
struct ClaudeConnector: QuotaConnector {
    static let autoSentinel = "auto:claude-code"
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Claude Code OAuth 토큰 엔드포인트/클라이언트 (Claude Code와 동일한 값).
    private static let oauthTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// 자격증명을 어디서 읽었는지 — 재발급 후 같은 곳에 다시 써서 Claude Code와
    /// 토큰을 동기화하기 위함(특히 refresh token이 회전되는 경우 필수).
    enum Source {
        case file(URL)
        case keychain(service: String, account: String?)
    }

    struct Credentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var source: Source?
    }

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        // 429 직후엔 아예 네트워크를 타지 않는다 — 식지 않은 채로 계속 재시도하면
        // 오히려 차단이 계속 연장될 수 있다("시간이 지나도 안 풀린다"는 증상의 원인).
        if let until = Self.rateLimitedUntil, until > Date() {
            throw ConnectorError.hint(Self.rateLimitHint(until: until))
        }

        let auto = credential == Self.autoSentinel
        let token = auto ? try await Self.autoAccessToken(forceRefresh: false) : credential
        let result = try await Self.fetchUsage(token: token)

        switch result.code {
        case 200:
            Self.rateLimitedUntil = nil
            return try Self.parseUsage(result.data)
        case 401 where auto, 403 where auto:
            // 토큰이 거부됨 → 강제 재발급(직접 OAuth → claude CLI) 후 1회 재시도.
            let freshToken = try await Self.autoAccessToken(forceRefresh: true)
            let retry = try await Self.fetchUsage(token: freshToken)
            if retry.code == 429 {
                let until = Self.cooldownDate(from: retry.response)
                Self.rateLimitedUntil = until
                throw ConnectorError.hint(Self.rateLimitHint(until: until))
            }
            guard retry.code == 200 else {
                throw ConnectorError.hint("인증 실패(\(retry.code)). 토큰을 재발급했지만 사용량 조회가 거부됐습니다. Claude Code를 한 번 실행해 로그인 상태를 확인하세요.")
            }
            Self.rateLimitedUntil = nil
            return try Self.parseUsage(retry.data)
        case 401, 403:
            throw ConnectorError.hint("인증 실패(\(result.code)). 토큰이 만료됐거나 잘못되었습니다. 계정 설정에서 '자동 감지 사용'을 누르면 Claude Code 자격증명을 매번 다시 읽고 만료 시 자동 재발급합니다.")
        case 429:
            let until = Self.cooldownDate(from: result.response)
            Self.rateLimitedUntil = until
            throw ConnectorError.hint(Self.rateLimitHint(until: until))
        default:
            throw ConnectorError.network("HTTP \(result.code)")
        }
    }

    /// 429 이후 다음 자동 재시도까지 기다리는 시각(nil이면 정상 상태).
    private static var rateLimitedUntil: Date?

    /// 429 응답의 Retry-After를 읽어 다음 시도 시각을 정한다. 헤더가 없으면 5분,
    /// 있어도 최소 1분은 쉰다(너무 짧은 힌트로 인한 재요청 폭주 방지).
    private static func cooldownDate(from response: HTTPURLResponse?) -> Date {
        let minimum: TimeInterval = 60
        let fallback: TimeInterval = 300
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After") else {
            return Date().addingTimeInterval(fallback)
        }
        if let seconds = TimeInterval(raw) {
            return Date().addingTimeInterval(max(seconds, minimum))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(date, Date().addingTimeInterval(minimum))
        }
        return Date().addingTimeInterval(fallback)
    }

    private static func rateLimitHint(until: Date) -> String {
        let minutes = max(1, Int(ceil(until.timeIntervalSinceNow / 60)))
        return "요청이 제한되었습니다(429). 계속 재시도하면 제한이 더 길어질 수 있어 약 \(minutes)분 쉬었다가 자동으로 다시 시도합니다."
    }

    // MARK: - 토큰 해석 / 하이브리드 재발급

    /// auto 모드에서 쓸 유효한 access token을 돌려준다.
    /// 토큰이 만료됐거나 `forceRefresh`면 하이브리드 재발급을 시도한다.
    private static func autoAccessToken(forceRefresh: Bool) async throws -> String {
        guard let creds = detectClaudeCodeCredentials(force: forceRefresh) else {
            throw ConnectorError.hint("Claude Code 자격증명을 찾지 못했습니다. Claude Code에 로그인돼 있는지 확인하세요.")
        }

        // 만료 60초 전이면 만료로 간주(시계 오차/네트워크 지연 대비).
        let expired = (creds.expiresAt ?? .distantFuture) <= Date().addingTimeInterval(60)

        if !forceRefresh && !expired {
            return creds.accessToken
        }

        // 만료됐는데 refresh token까지 비어 있으면 갱신이 원천 불가 → 재로그인 안내.
        // (Claude Code 자격증명 자체가 만료/손상된 상태. QuotaBar가 고칠 수 없음.)
        let hasRefresh = !((creds.refreshToken ?? "").isEmpty)
        if expired && !hasRefresh {
            throw ConnectorError.hint("Claude Code 로그인이 만료됐습니다(저장된 토큰 만료 + refresh 토큰 없음). 터미널에서 `claude` 실행 → `/login`으로 다시 로그인하면 해결됩니다.")
        }

        reissueDiag = nil
        if let refreshed = await reissueToken(from: creds) {
            return refreshed.accessToken
        }

        // 재발급 실패: 토큰이 아직 유효하면 일단 그걸로 시도(호출부가 최종 에러 처리).
        if !expired {
            return creds.accessToken
        }
        throw ConnectorError.hint("Claude Code 토큰 재발급에 실패했습니다. (\(reissueDiag ?? "원인 불명")) Claude Code를 한 번 실행해 로그인 상태를 갱신하세요.")
    }

    /// 하이브리드 재발급:
    /// 1) 저장된 refresh token으로 OAuth 토큰을 직접 갱신 (빠름, 쿼터 소모 없음)
    /// 2) 실패하면 `claude` CLI를 한 번 실행해 Claude Code가 직접 갱신하게 함
    /// 성공하면 회전된 토큰을 원본(파일/키체인)에 다시 쓰고 메모리 캐시도 갱신한다.
    private static func reissueToken(from creds: Credentials) async -> Credentials? {
        // 1) OAuth 직접 갱신 — 항상 최신 refresh token으로 시도(Claude Code와의 회전 경합 최소화).
        let latest = detectClaudeCodeCredentials(force: true) ?? creds
        if let refreshed = await refreshViaOAuth(latest) {
            persist(refreshed)                  // 회전된 refresh token을 원본에 반영(중요).
            cachedCredentials = (refreshed, Date())
            return refreshed
        }
        // 2) claude CLI 폴백 — Claude Code가 스스로 갱신/저장하게 한다.
        if await runClaudeCodeRefresh() {
            cachedCredentials = nil             // 디스크/키체인이 바뀌었으니 캐시 무효화.
            if let fresh = detectClaudeCodeCredentials(force: true),
               (fresh.expiresAt ?? .distantFuture) > Date() {
                return fresh
            }
            appendDiag("claude CLI 실행 후에도 유효한 토큰을 못 읽음")
        } else {
            appendDiag(locateClaudeBinary() == nil ? "claude 실행파일을 찾지 못함" : "claude CLI 실행 실패")
        }
        return nil
    }

    /// 재발급 실패 원인 진단(사용자 안내 메시지에 노출).
    private static var reissueDiag: String?
    private static func appendDiag(_ msg: String) {
        reissueDiag = reissueDiag.map { $0 + "; " + msg } ?? msg
    }

    /// refresh token으로 OAuth 토큰을 직접 갱신한다. 실패하면 nil.
    private static func refreshViaOAuth(_ creds: Credentials) async -> Credentials? {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            appendDiag("refresh token이 자격증명에 없음")
            return nil
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ]
        guard let (data, code) = try? await HTTP.post(oauthTokenURL,
                  headers: ["User-Agent": "anthropic", "Accept": "application/json"],
                  jsonBody: body) else {
            appendDiag("OAuth 갱신 요청 실패(네트워크)")
            return nil
        }
        guard code == 200 else {
            let snippet = String(data: data.prefix(180), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            appendDiag("OAuth 갱신 거부(HTTP \(code)) \(snippet)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = (json["access_token"] as? String) ?? (json["accessToken"] as? String),
              !access.isEmpty else {
            appendDiag("OAuth 응답에 access_token 없음")
            return nil
        }

        var updated = creds
        updated.accessToken = access
        // refresh token은 회전될 수 있다 — 새 값이 오면 교체, 없으면 기존 유지.
        updated.refreshToken = (json["refresh_token"] as? String)
            ?? (json["refreshToken"] as? String)
            ?? creds.refreshToken
        updated.expiresAt = expiry(from: json) ?? creds.expiresAt
        return updated
    }

    private static func expiry(from json: [String: Any]) -> Date? {
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

    private static func fetchUsage(token: String) async throws -> (data: Data, code: Int, response: HTTPURLResponse?) {
        // User-Agent가 실제 설치된 Claude Code 버전과 어긋나면 공격적으로 429가 떨어진다.
        // 버전을 하드코딩하지 않고 `claude --version`으로 매번 자동 감지한다(1시간 캐시).
        let userAgent = await detectedUserAgent()
        return try await HTTP.getWithResponse(Self.url, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": userAgent,
            "Accept": "application/json",
        ])
    }

    private static var cachedCLIVersion: (value: String, fetchedAt: Date)?

    /// 로컬 Claude Code CLI의 실제 버전을 감지해 "claude-code/x.y.z" 형태로 반환한다.
    /// 감지에 실패하면 마지막으로 알려진 값, 그마저 없으면 예전 하드코딩값으로 폴백한다.
    private static func detectedUserAgent() async -> String {
        let fallback = "claude-code/2.0.0"
        if let cached = cachedCLIVersion, Date().timeIntervalSince(cached.fetchedAt) < 3600 {
            return "claude-code/\(cached.value)"
        }
        let version = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: detectCLIVersionSync())
            }
        }
        guard let version else {
            return cachedCLIVersion.map { "claude-code/\($0.value)" } ?? fallback
        }
        cachedCLIVersion = (version, Date())
        return "claude-code/\(version)"
    }

    private static func detectCLIVersionSync() -> String? {
        guard let bin = locateClaudeBinary() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression)
        else { return nil }
        return String(output[match])
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

    // MARK: - 새 토큰 영속화 (Claude Code와 동기화)

    /// 재발급된 자격증명을 읽어온 원본에 다시 쓴다.
    /// refresh token이 회전되는 경우, 이걸 안 하면 다음번에 Claude Code 자신의
    /// 토큰 갱신이 깨질 수 있으므로 반드시 동기화한다. (best-effort)
    private static func persist(_ creds: Credentials) {
        guard let source = creds.source else { return }
        switch source {
        case .file(let url):
            persistToFile(creds, url: url)
        case .keychain(let service, let account):
            persistToKeychain(creds, service: service, account: account)
        }
    }

    private static func persistToFile(_ creds: Credentials, url: URL) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let data = raw.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if var oauth = json["claudeAiOauth"] as? [String: Any] {
            applyTokens(to: &oauth, from: creds)
            json["claudeAiOauth"] = oauth
        } else {
            applyTokens(to: &json, from: creds)
        }

        guard let out = try? JSONSerialization.data(withJSONObject: json,
                  options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: url, options: [.atomic])
    }

    private static func persistToKeychain(_ creds: Credentials, service: String, account: String?) {
        // 기존 키체인 JSON을 읽어 토큰만 갱신해 다시 저장(추가 필드/구조 보존).
        guard let raw = runSecurityCLI(service: service),
              let data = raw.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if var oauth = json["claudeAiOauth"] as? [String: Any] {
            applyTokens(to: &oauth, from: creds)
            json["claudeAiOauth"] = oauth
        } else {
            applyTokens(to: &json, from: creds)
        }

        guard let out = try? JSONSerialization.data(withJSONObject: json),
              let outStr = String(data: out, encoding: .utf8) else { return }

        // 업데이트는 service+account로 항목을 식별한다. account를 모르는 채로 저장하면
        // 빈 account의 '다른' 항목을 새로 만들어 Claude Code의 항목과 충돌할 수 있으므로,
        // 식별 불가 시 키체인은 건드리지 않는다(파일 쪽은 이미 갱신됨).
        guard let acct = (account ?? keychainAccount(service: service)), !acct.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        let args = ["add-generic-password", "-U", "-s", service, "-a", acct, "-w", outStr]
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// 존재하는 키 스타일(camelCase / snake_case)을 보존하며 토큰 필드를 갱신.
    private static func applyTokens(to dict: inout [String: Any], from creds: Credentials) {
        let accessKey = dict["access_token"] != nil ? "access_token" : "accessToken"
        dict[accessKey] = creds.accessToken

        if let refresh = creds.refreshToken {
            let refreshKey = dict["refresh_token"] != nil ? "refresh_token" : "refreshToken"
            dict[refreshKey] = refresh
        }
        if let expiresAt = creds.expiresAt {
            if dict["expires_at"] != nil {
                dict["expires_at"] = Int(expiresAt.timeIntervalSince1970)         // 초
            } else {
                dict["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)   // ms (Claude Code 표준)
            }
        }
    }

    // MARK: - claude CLI 폴백

    /// `claude` 실행파일을 찾아 비대화식으로 한 번 실행한다.
    /// Claude Code가 인증 초기화 중 만료 토큰을 자동 갱신·저장하므로, 실행 후
    /// 파일/키체인을 다시 읽으면 새 토큰을 얻을 수 있다.
    private static func runClaudeCodeRefresh() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runClaudeCodeRefreshSync())
            }
        }
    }

    private static func runClaudeCodeRefreshSync() -> Bool {
        guard let bin = locateClaudeBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        // 짧은 비대화식 호출: Claude Code가 인증 초기화 중 만료 토큰을 갱신한다.
        process.arguments = ["-p", "ping", "--max-turns", "1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        // 워치독: 90초가 넘으면 강제 종료(그 시점이면 토큰 갱신은 이미 끝났을 것).
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        return true
    }

    private static func locateClaudeBinary() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/usr/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return whichClaude()
    }

    /// 로그인 셸을 통해 PATH에서 claude를 찾는다(GUI 앱은 셸 PATH를 안 물려받음).
    private static func whichClaude() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Claude Code 자격증명 감지

    /// ~/.claude/.credentials.json 등을 먼저 읽고, 없으면 키체인을 UI 없이 조회한다.
    /// 만료된 자격증명도 (refresh token 확보를 위해) 반환하되, 캐시는 유효한 것만 한다.
    /// 결과는 최대 10분간 메모리에 캐시한다.
    private static var cachedCredentials: (value: Credentials, fetchedAt: Date)?

    static func detectClaudeCodeCredentials(force: Bool = false) -> Credentials? {
        if !force, let cached = cachedCredentials,
           Date().timeIntervalSince(cached.fetchedAt) < 600,
           (cached.value.expiresAt ?? .distantFuture) > Date() {
            return cached.value
        }
        let creds = freshestCredentials()
        if let creds, (creds.expiresAt ?? .distantFuture) > Date() {
            cachedCredentials = (creds, Date())   // 유효한 자격증명만 캐시.
        }
        return creds
    }

    /// 파일·키체인의 모든 후보 중 가장 최신(만료가 가장 늦은) 자격증명을 고른다.
    /// 파일에 유효한 토큰이 있으면 키체인은 건드리지 않는다(불필요한 키체인 프롬프트 방지).
    /// 파일이 없거나 모두 만료된 경우에만 키체인까지 포함해, **만료된 파일 토큰이
    /// 키체인의 최신 토큰을 가리는 문제**를 막는다.
    private static func freshestCredentials() -> Credentials? {
        let now = Date()
        let fileCands = fileCredentialCandidates()
        if let validFile = latest(of: fileCands.filter({ ($0.expiresAt ?? .distantFuture) > now })) {
            return validFile
        }
        var all = fileCands
        all.append(contentsOf: keychainCredentialCandidates())
        guard !all.isEmpty else { return nil }
        let valid = all.filter { ($0.expiresAt ?? .distantFuture) > now }
        return latest(of: valid.isEmpty ? all : valid)
    }

    /// expiresAt이 가장 늦은 자격증명(없으면 nil). nil 만료는 무한대로 간주.
    private static func latest(of creds: [Credentials]) -> Credentials? {
        creds.max { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    private static func fileCredentialCandidates() -> [Credentials] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude.json"),
            home.appendingPathComponent(".config/claude/credentials.json"),
        ]
        var out: [Credentials] = []
        for path in files {
            if let raw = try? String(contentsOf: path, encoding: .utf8),
               var creds = parse(credentialJSON: raw) {
                creds.source = .file(path)
                out.append(creds)
            }
        }
        return out
    }

    private static func keychainCredentialCandidates() -> [Credentials] {
        let services = [
            "Claude Code-credentials",
            "Claude Code",
            "claude-code",
        ]
        var out: [Credentials] = []
        for service in services {
            // 네이티브 Security API 우선 — 접근 창이 'QuotaBar' 이름으로 떠서 한 번
            // '항상 허용'하면 ACL에 QuotaBar가 추가돼 이후엔 무프롬프트로 읽힌다.
            // (security CLI는 다른 앱이 만든 ACL 제한 항목을 백그라운드에서 못 읽는 경우가 많음.)
            let raw = keychainRawViaAPI(service: service) ?? runSecurityCLI(service: service)
            if let raw, var creds = parse(credentialJSON: raw) {
                // account는 갱신 저장 때만 필요 → 그때 조회(불필요한 키체인 프롬프트 방지).
                creds.source = .keychain(service: service, account: nil)
                out.append(creds)
            }
        }
        return out
    }

    /// Security 프레임워크로 키체인 generic password를 직접 읽는다.
    /// 다른 앱(Claude Code)이 만든 ACL 제한 항목이면 첫 읽기에서 사용자 승인 창이 뜨고,
    /// '항상 허용'을 누르면 QuotaBar가 항목 ACL에 추가돼 이후엔 조용히 읽힌다.
    private static func keychainRawViaAPI(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty
        else { return nil }
        return str
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

    /// 키체인 항목의 account 속성을 읽는다(갱신 저장 시 업데이트 대상 식별용).
    private static func keychainAccount(service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-g"]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 예) "acct"<blob>="user@example.com"
        for line in text.split(separator: "\n") where line.contains("\"acct\"") {
            if let r = line.range(of: "=\"") {
                let after = line[r.upperBound...]
                if let end = after.firstIndex(of: "\"") {
                    let acct = String(after[..<end])
                    if !acct.isEmpty { return acct }
                }
            }
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
        let refresh = (oauth["refreshToken"] as? String) ?? (oauth["refresh_token"] as? String)
        var expiresAt: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let seconds = (oauth["expires_at"] as? NSNumber)?.doubleValue, seconds > 0 {
            expiresAt = Date(timeIntervalSince1970: seconds)
        }
        return Credentials(accessToken: token, refreshToken: refresh,
                           expiresAt: expiresAt, source: nil)
    }
}
