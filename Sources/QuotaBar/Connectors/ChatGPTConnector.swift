import Foundation

/// ChatGPT (Plus) — Codex CLI가 쓰는 사용량 엔드포인트에서
/// 5시간/주간 한도 사용률을 가져온다. 비공식 엔드포인트.
///
/// 인증 모드:
/// 1. `auto:codex` 센티널 — 매 갱신마다 ~/.codex/auth.json (Codex CLI 자격증명)을
///    실시간으로 읽는다. Codex CLI에 로그인돼 있으면 그대로 동작. (권장)
/// 2. 직접 붙여넣은 액세스 토큰.
///
/// 주의: 이 한도는 Codex(ChatGPT 플랜의 코딩 에이전트) 레인 기준이다.
/// 웹 채팅 메시지 캡(GPT 메시지/3시간 등)은 조회 경로가 없어 기본 쿼터에서 제외한다.
struct ChatGPTConnector: QuotaConnector {
    static let autoSentinel = "auto:codex"
    private static let defaultBase = "https://chatgpt.com/backend-api"

    /// `$CODEX_HOME/config.toml`의 `chatgpt_base_url`을 존중한다 (없으면 기본 호스트).
    private static var usageURL: URL {
        var base = defaultBase
        if let toml = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8) {
            for line in toml.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("chatgpt_base_url") else { continue }
                let value = trimmed.split(separator: "=", maxSplits: 1).last
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? ""
                if value.hasPrefix("http") { base = value }
            }
        }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/wham/usage") ?? URL(string: defaultBase + "/wham/usage")!
    }

    /// `$CODEX_HOME` 또는 `~/.codex`
    static var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    struct Credentials {
        var accessToken: String
        var accountId: String?
        /// id_token JWT 클레임에서 읽은 플랜 (예: "plus", "pro")
        var planFromJWT: String?
        /// 토큰 만료 시각(JWT exp)
        var expiresAt: Date?
    }

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let creds: Credentials
        if credential == Self.autoSentinel {
            guard let detected = Self.detectCodexCredentials() else {
                throw ConnectorError.hint("Codex CLI 자격증명(~/.codex/auth.json)을 찾지 못했습니다. `codex login` 후 다시 시도하세요.")
            }
            creds = detected
        } else {
            creds = Credentials(accessToken: credential, accountId: nil, planFromJWT: nil, expiresAt: nil)
        }

        // 토큰이 만료 임박이면 CLI가 스스로 갱신하도록 한다 (CodexBar와 같은 방침: auth.json을 직접 쓰지 않는다).
        if credential == Self.autoSentinel, let exp = creds.expiresAt, exp < Date().addingTimeInterval(300) {
            if let viaCLI = await Self.fetchViaAppServer() { return viaCLI }
        }

        var headers: [String: String] = [
            "Authorization": "Bearer \(creds.accessToken)",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs",
        ]
        if let accountId = creds.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }

        let (data, code) = try await HTTP.get(Self.usageURL, headers: headers)
        switch code {
        case 200: break
        case 401, 403:
            // 2순위: Codex CLI의 app-server(JSON-RPC)로 직접 조회 — CLI가 토큰 갱신까지 처리한다.
            if credential == Self.autoSentinel, let viaCLI = await Self.fetchViaAppServer() { return viaCLI }
            throw ConnectorError.hint("인증 실패(\(code)). Codex CLI를 한 번 실행하거나 `codex login`으로 토큰을 갱신하세요.")
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.network("HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.schemaChanged("JSON 아님")
        }

        var updates: [QuotaUpdate] = []
        let plan = PlanDetection.normalize(json["plan_type"] as? String)
            ?? PlanDetection.from(json: json) ?? PlanDetection.normalize(creds.planFromJWT)
        let container = (json["rate_limit"] as? [String: Any])
            ?? (json["rate_limits"] as? [String: Any])
            ?? json

        if let window = container["primary_window"] as? [String: Any],
           let update = Self.parseWindow(window, key: "codex_primary", name: "Codex 세션 (5시간)") {
            updates.append(update.withPlan(plan))
        }
        if let window = container["secondary_window"] as? [String: Any],
           let update = Self.parseWindow(window, key: "codex_secondary", name: "Codex 주간") {
            updates.append(update.withPlan(plan))
        }

        // 추가 한도 (모델별/코드리뷰 등)
        if let extras = json["additional_rate_limits"] as? [[String: Any]] {
            for (index, extra) in extras.enumerated() {
                let name = (extra["name"] as? String)
                    ?? (extra["limit_name"] as? String)
                    ?? "추가 한도 \(index + 1)"
                let windowObj = (extra["window"] as? [String: Any]) ?? extra
                if let update = Self.parseWindow(windowObj,
                                                 key: "codex_extra_\(index)",
                                                 name: "Codex \(name)") {
                    updates.append(update.withPlan(plan))
                }
            }
        }

        guard !updates.isEmpty else {
            throw ConnectorError.schemaChanged("primary_window/secondary_window 필드 없음")
        }
        return updates
    }

    /// 윈도우 객체에서 사용률(%)과 리셋 시각을 관대하게 파싱
    private static func parseWindow(_ obj: [String: Any], key: String, name: String) -> QuotaUpdate? {
        let percent = (obj["used_percent"] as? NSNumber)?.doubleValue
            ?? (obj["utilization"] as? NSNumber)?.doubleValue
            ?? (obj["percent_used"] as? NSNumber)?.doubleValue
        guard let percent, percent.isFinite else { return nil }

        var resetsAt: Date?
        if let seconds = (obj["resets_in_seconds"] as? NSNumber)?.doubleValue
            ?? (obj["reset_after_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = Date().addingTimeInterval(seconds)
        } else if let raw = obj["resets_at"] {
            if let str = raw as? String {
                resetsAt = DateParsing.iso8601(str)
            } else if let epoch = (raw as? NSNumber)?.doubleValue, epoch > 0 {
                resetsAt = Date(timeIntervalSince1970: epoch)
            }
        }
        return QuotaUpdate(key: key, name: name, used: percent,
                           cap: 100, unit: "%", resetsAt: resetsAt)
    }

    // MARK: - Codex CLI 자격증명 감지

    static func codexAuthExists() -> Bool {
        detectCodexCredentials() != nil
    }

    static func detectCodexCredentials() -> Credentials? {
        let path = codexHome.appendingPathComponent("auth.json")
        // 쓰는 도중인 파일을 읽을 수 있어 짧게 두 번 재시도 (CodexBar와 동일)
        var data: Data?
        for attempt in 0..<3 {
            data = try? Data(contentsOf: path)
            if data != nil, (try? JSONSerialization.jsonObject(with: data!)) != nil { break }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 일반적 구조: {"tokens": {"access_token": ..., "id_token": ..., "account_id": ...}, ...}
        let tokens = (json["tokens"] as? [String: Any]) ?? json
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        let accountId = (tokens["account_id"] as? String)
            ?? (json["account_id"] as? String)
        let idClaims = (tokens["id_token"] as? String).flatMap(jwtClaims)
        let authClaims = idClaims?["https://api.openai.com/auth"] as? [String: Any]
        let plan = authClaims?["chatgpt_plan_type"] as? String
        let exp = jwtClaims(accessToken)?["exp"] as? NSNumber
        return Credentials(accessToken: accessToken,
                           accountId: accountId ?? (authClaims?["chatgpt_account_id"] as? String),
                           planFromJWT: plan,
                           expiresAt: exp.map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    /// JWT payload(서명 검증 없음 — 표시용 클레임만 읽는다)
    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Codex CLI app-server (JSON-RPC) 폴백

    /// `codex -s read-only -a never app-server`에 JSON-RPC로 `account/rateLimits/read`를 요청한다.
    /// 실패하면 nil (호출부가 원래 오류를 낸다). 응답 필드명은 버전에 따라 달라 관대하게 파싱한다.
    static func fetchViaAppServer() async -> [QuotaUpdate]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[QuotaUpdate]?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runAppServerSync())
            }
        }
    }

    private static func runAppServerSync() -> [QuotaUpdate]? {
        guard let bin = locateCodexBinary() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }
        // 응답이 없어도 읽기가 영원히 막히지 않도록 10초 뒤 프로세스를 종료한다.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }

        func send(_ obj: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0A)
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "quotabar", "title": "QuotaBar", "version": "2.0"]]])
        send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
        send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])

        // 응답 줄을 최대 10초 동안 읽는다.
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        let handle = stdout.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for line in buffer.split(separator: 0x0A) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == 2,
                      let result = obj["result"] as? [String: Any] else { continue }
                return parseRPCRateLimits(result)
            }
        }
        return nil
    }

    private static func parseRPCRateLimits(_ result: [String: Any]) -> [QuotaUpdate]? {
        let limits = (result["rateLimits"] as? [String: Any]) ?? result
        var updates: [QuotaUpdate] = []
        for (field, key, name) in [("primary", "codex_primary", "Codex 세션 (5시간)"),
                                   ("secondary", "codex_secondary", "Codex 주간")] {
            guard let w = limits[field] as? [String: Any] else { continue }
            let used = (w["usedPercent"] as? NSNumber)?.doubleValue
                ?? (w["used_percent"] as? NSNumber)?.doubleValue
            guard let used else { continue }
            var resets: Date?
            if let t = (w["resetsAt"] as? NSNumber)?.doubleValue ?? (w["resets_at"] as? NSNumber)?.doubleValue, t > 0 {
                resets = Date(timeIntervalSince1970: t > 1_000_000_000_000 ? t / 1000 : t)
            }
            updates.append(QuotaUpdate(key: key, name: name, used: used, cap: 100, unit: "%", resetsAt: resets))
        }
        return updates.isEmpty ? nil : updates
    }

    private static func locateCodexBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.local/bin/codex", "\(home)/.bun/bin/codex",
                          "\(home)/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private extension QuotaUpdate {
    func withPlan(_ planName: String?) -> QuotaUpdate {
        QuotaUpdate(key: key, name: name, used: used, cap: cap, unit: unit,
                    resetsAt: resetsAt, planName: planName)
    }
}
