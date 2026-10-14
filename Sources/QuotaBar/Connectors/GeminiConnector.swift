import Foundation

/// Gemini
///
/// 1순위(가능한 계정만): Gemini CLI의 OAuth 로그인(`~/.gemini/oauth_creds.json`)으로 Code Assist
///   `v1internal:retrieveUserQuota`를 조회해 모델별(Pro/Flash/Flash Lite) 서버 잔량을 가져온다.
///   ※ Google은 2026-06-18부로 개인·AI Pro·Ultra 계정의 Gemini CLI OAuth를 종료했다. 이런 계정은
///     `SUBSCRIPTION_REQUIRED`(403)가 오므로 조용히 건너뛰고 2순위로 내려간다. Workspace/Code Assist
///     Standard 계정은 계속 동작한다.
/// 2순위(항상): ~/.gemini 로컬 기록을 읽어 최근 활동량을 자동 추정한다. 서버가 계산하는 실제
///   compute quota와는 다를 수 있다.
struct GeminiConnector: QuotaConnector {
    static let autoSentinel = "auto:gemini-local"

    func fetch(credential: String, context: ConnectorContext?) async throws -> [QuotaUpdate] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiRoot = home.appendingPathComponent(".gemini")
        let tmpRoot = geminiRoot.appendingPathComponent("tmp")
        let historyRoot = geminiRoot.appendingPathComponent("history")

        guard FileManager.default.fileExists(atPath: geminiRoot.path) else {
            throw ConnectorError.hint("Gemini 로컬 기록(~/.gemini)을 찾지 못했습니다. Gemini CLI나 Gemini 앱을 한 번 실행한 뒤 다시 시도하세요.")
        }

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let dayStart = LocalActivity.startOfToday()

        let roots = [tmpRoot, historyRoot]
        let fiveHourCount = LocalActivity.countJSONLogEvents(roots: roots, since: fiveHoursAgo)
        let dayCount = LocalActivity.countJSONLogEvents(roots: roots, since: dayStart)
        let researchCount = LocalActivity.countJSONLogEvents(
            roots: roots,
            since: dayStart,
            messageField: "message",
            messageContainsAny: ["deep research", "딥리서치", "딥 리서치", "심층 조사"]
        )

        let local = [
            QuotaUpdate(key: "gemini_5h", name: "Gemini 활동 (5시간)",
                        used: fiveHourCount, cap: 100, unit: "회",
                        resetsAt: now.addingTimeInterval(5 * 3600)),
            QuotaUpdate(key: "gemini_day", name: "Gemini 활동 (오늘)",
                        used: dayCount, cap: 100, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .day, value: 1, to: dayStart)),
            QuotaUpdate(key: "gemini_deep_research", name: "Deep Research",
                        used: researchCount, cap: 20, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .day, value: 1, to: dayStart)),
        ]
        // 서버 잔량을 읽을 수 있으면 앞에 붙이고, 아니면 로컬 추정만 돌려준다.
        // 로컬 추정에는 플랜 정보가 없으므로 플랜명은 서버 조회로 감지된 경우에만 표시한다.
        if let remote = await Self.fetchServerQuota(geminiRoot: geminiRoot) {
            return remote + local
        }
        return local
    }

    // MARK: - Code Assist 서버 잔량

    private static let codeAssist = "https://cloudcode-pa.googleapis.com/v1internal"

    private static func fetchServerQuota(geminiRoot: URL) async -> [QuotaUpdate]? {
        // 인증 방식이 oauth-personal(또는 미지정)일 때만 시도
        if let data = try? Data(contentsOf: geminiRoot.appendingPathComponent("settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = ((json["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
            ?? (json["selectedAuthType"] as? String),
           auth != "oauth-personal" { return nil }

        guard let data = try? Data(contentsOf: geminiRoot.appendingPathComponent("oauth_creds.json")),
              let creds = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = creds["access_token"] as? String, !token.isEmpty else { return nil }
        // 만료된 토큰은 갱신하지 않는다 (Gemini CLI가 갱신) — 로컬 추정으로 폴백
        if let expiry = (creds["expiry_date"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: expiry / 1000) < Date().addingTimeInterval(60) { return nil }

        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]

        // 프로젝트/티어 확인
        var projectID: String?
        var plan: String?
        if let url = URL(string: codeAssist + ":loadCodeAssist"),
           let (d, code) = try? await HTTP.post(url, headers: headers, jsonBody: [
               "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]),
           code == 200,
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            projectID = obj["cloudaicompanionProject"] as? String
            let paid = (obj["paidTier"] as? [String: Any])?["name"] as? String
            let current = (obj["currentTier"] as? [String: Any])?["name"] as? String
            plan = PlanDetection.normalize(paid ?? current)
            // 소비자 계정 종료: currentTier 없음 + ineligibleTiers → 서버 조회 불가
            if obj["currentTier"] == nil, obj["ineligibleTiers"] != nil { return nil }
        }

        var quotaBody: [String: Any] = [:]
        if let projectID { quotaBody["project"] = projectID }
        guard let url = URL(string: codeAssist + ":retrieveUserQuota"),
              let (d, code) = try? await HTTP.post(url, headers: headers, jsonBody: quotaBody),
              code == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let buckets = obj["buckets"] as? [[String: Any]] else { return nil }

        // 모델 계열별로 가장 빡빡한(remainingFraction 최소) 버킷을 고른다.
        var best: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = (bucket["modelId"] as? String)?.lowercased(),
                  let fraction = (bucket["remainingFraction"] as? NSNumber)?.doubleValue else { continue }
            let family = model.contains("flash-lite") ? "flash_lite" : model.contains("flash") ? "flash"
                : model.contains("pro") ? "pro" : nil
            guard let family else { continue }
            let reset = DateParsing.iso8601(bucket["resetTime"] as? String)
            if best[family] == nil || fraction < best[family]!.fraction {
                best[family] = (fraction, reset)
            }
        }
        let names = [("pro", "Gemini Pro"), ("flash", "Gemini Flash"), ("flash_lite", "Gemini Flash Lite")]
        let updates = names.compactMap { family, name -> QuotaUpdate? in
            guard let b = best[family] else { return nil }
            return QuotaUpdate(key: "gemini_\(family)_quota", name: "\(name) 한도",
                               used: ((1 - min(max(b.fraction, 0), 1)) * 100).rounded(),
                               cap: 100, unit: "%", resetsAt: b.reset, planName: plan)
        }
        return updates.isEmpty ? nil : updates
    }
}
