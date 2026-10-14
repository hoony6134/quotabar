import Foundation

/// 커넥터가 돌려주는 쿼터 갱신값. `key`로 계정의 QuotaItem과 매칭된다.
struct QuotaUpdate {
    var key: String
    var name: String?
    var used: Double
    var cap: Double?
    var unit: String?
    var resetsAt: Date?
    var planName: String? = nil
    /// 이 토큰이 어느 계정/조직의 것인지 (예: "me@example.com · TexCorps (Team)"). 계정 카드에 표시된다.
    var accountIdentity: String? = nil
}

/// 커넥터가 계정 단위 부수효과(갱신된 자격증명 저장 등)를 요청할 때 쓰는 컨텍스트.
struct ConnectorContext {
    var accountID: UUID
    /// 커넥터가 자격증명을 갱신(OAuth 토큰 회전 등)했을 때 새 값을 저장해 달라는 콜백.
    /// 회전된 refresh token을 저장하지 않으면 다음 갱신이 실패하므로 커넥터는 회전 직후 바로 호출한다.
    var persistCredential: @MainActor (String) -> Void
}

enum ConnectorError: LocalizedError {
    case noCredential
    case unauthorized
    case rateLimited
    case schemaChanged(String)
    case network(String)
    case hint(String)

    var errorDescription: String? {
        switch self {
        case .noCredential:         return "인증 정보가 없습니다. 계정 설정에서 토큰을 입력하세요."
        case .unauthorized:         return "인증 실패 (401/403). 토큰이 만료됐거나 잘못되었습니다."
        case .rateLimited:          return "요청이 제한되었습니다 (429). 잠시 후 다시 시도하세요."
        case .schemaChanged(let s): return "응답 형식을 해석하지 못했습니다: \(s). 서비스 API가 변경된 것 같습니다."
        case .network(let s):       return "네트워크 오류: \(s)"
        case .hint(let s):          return s
        }
    }
}

protocol QuotaConnector {
    /// 인증 토큰으로 서비스 사용량을 조회한다.
    /// - Parameter context: 자격증명 갱신 저장 등 계정 단위 콜백 (없으면 커넥터는 저장을 건너뛴다).
    func fetch(credential: String, context: ConnectorContext?) async throws -> [QuotaUpdate]
}

// MARK: - 공용 HTTP / 날짜 유틸

enum HTTP {
    static func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await run(request)
    }

    static func post(_ url: URL, headers: [String: String], jsonBody: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await run(request)
    }

    /// GET이지만 응답 헤더까지 필요한 커넥터(예: 429의 Retry-After)를 위한 버전.
    static func getWithResponse(_ url: URL, headers: [String: String]) async throws -> (data: Data, code: Int, response: HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, http)
        } catch {
            throw ConnectorError.network(error.localizedDescription)
        }
    }

    private static func run(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            throw ConnectorError.network(error.localizedDescription)
        }
    }
}

enum DateParsing {
    /// ISO8601 (소수점 초 유무 모두) 파싱
    static func iso8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

enum PlanDetection {
    static func from(json: [String: Any]) -> String? {
        scan(json)
    }

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.contains("ultra") { return "Ultra" }
        if lower.contains("max") { return "Max" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") || lower.contains("business") { return "Enterprise" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("edu") || lower.contains("student") { return "Edu" }
        if lower.contains("free") { return "Free" }
        return trimmed
    }

    /// Claude 플랜명: 조직 종류(`claude_team`/`claude_max`/`claude_pro`…)를 우선 쓰고,
    /// 레이트리밋 티어(`default_claude_max_5x` 등)에 배수가 있으면 덧붙인다. 예: "Max 5x", "Team".
    static func claudePlan(organizationType: String?, subscriptionType: String?, rateLimitTier: String?) -> String? {
        let base = normalize(organizationType?.replacingOccurrences(of: "claude_", with: ""))
            ?? normalize(subscriptionType)
        guard let base else { return nil }
        let tier = (rateLimitTier ?? "").lowercased()
        if let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            return "\(base) \(tier[range])"
        }
        return base
    }

    private static func scan(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            let priorityKeys = [
                "plan", "plan_name", "plan_type", "subscription_plan",
                "subscription_tier", "tier", "account_plan", "sku"
            ]
            for key in priorityKeys {
                if let found = normalize(dict[key] as? String) { return found }
            }
            for (key, value) in dict {
                let lower = key.lowercased()
                if lower.contains("plan") || lower.contains("tier") || lower.contains("subscription") {
                    if let found = normalize(value as? String) { return found }
                }
            }
            for value in dict.values {
                if let found = scan(value) { return found }
            }
        } else if let array = value as? [Any] {
            for value in array {
                if let found = scan(value) { return found }
            }
        }
        return nil
    }
}
