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
    private static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    struct Credentials {
        var accessToken: String
        var accountId: String?
    }

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let creds: Credentials
        if credential == Self.autoSentinel {
            guard let detected = Self.detectCodexCredentials() else {
                throw ConnectorError.hint("Codex CLI 자격증명(~/.codex/auth.json)을 찾지 못했습니다. `codex login` 후 다시 시도하세요.")
            }
            creds = detected
        } else {
            creds = Credentials(accessToken: credential, accountId: nil)
        }

        var headers: [String: String] = [
            "Authorization": "Bearer \(creds.accessToken)",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs",
        ]
        if let accountId = creds.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }

        let (data, code) = try await HTTP.get(Self.url, headers: headers)
        switch code {
        case 200: break
        case 401, 403:
            throw ConnectorError.hint("인증 실패(\(code)). Codex CLI를 한 번 실행하거나 `codex login`으로 토큰을 갱신하세요.")
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.network("HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.schemaChanged("JSON 아님")
        }

        var updates: [QuotaUpdate] = []
        let container = (json["rate_limit"] as? [String: Any])
            ?? (json["rate_limits"] as? [String: Any])
            ?? json

        if let window = container["primary_window"] as? [String: Any],
           let update = Self.parseWindow(window, key: "codex_primary", name: "Codex 세션 (5시간)") {
            updates.append(update.withPlan(PlanDetection.from(json: json)))
        }
        if let window = container["secondary_window"] as? [String: Any],
           let update = Self.parseWindow(window, key: "codex_secondary", name: "Codex 주간") {
            updates.append(update.withPlan(PlanDetection.from(json: json)))
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
                    updates.append(update.withPlan(PlanDetection.from(json: json)))
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
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 일반적 구조: {"tokens": {"access_token": ..., "account_id": ...}, ...}
        let tokens = (json["tokens"] as? [String: Any]) ?? json
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        let accountId = (tokens["account_id"] as? String)
            ?? (json["account_id"] as? String)
        return Credentials(accessToken: accessToken, accountId: accountId)
    }
}

private extension QuotaUpdate {
    func withPlan(_ planName: String?) -> QuotaUpdate {
        QuotaUpdate(key: key, name: name, used: used, cap: cap, unit: unit,
                    resetsAt: resetsAt, planName: planName)
    }
}
