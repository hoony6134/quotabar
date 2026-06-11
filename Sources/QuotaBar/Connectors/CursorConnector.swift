import Foundation

/// Cursor — 대시보드가 쓰는 비공식 API. 세션 쿠키(WorkosCursorSessionToken)로 인증.
/// 요금제 개편이 잦아서 두 가지 엔드포인트를 시도하고, 파싱되는 것만 반영한다.
struct CursorConnector: QuotaConnector {

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectorError.noCredential }

        let cookie = "WorkosCursorSessionToken=\(token)"
        var updates: [QuotaUpdate] = []
        var lastError: Error?

        // 1) 레거시 사용량 (요청 횟수 기반)
        do {
            updates.append(contentsOf: try await fetchLegacyUsage(cookie: cookie, token: token))
        } catch { lastError = error }

        // 2) 이번 달 인보이스 (사용량 기반 과금 합계, $)
        do {
            if let update = try await fetchMonthlyInvoice(cookie: cookie) {
                updates.append(update)
            }
        } catch { lastError = error }

        if updates.isEmpty {
            throw lastError ?? ConnectorError.schemaChanged("사용 가능한 엔드포인트 없음")
        }
        return updates
    }

    // MARK: - 레거시 /api/usage

    private func fetchLegacyUsage(cookie: String, token: String) async throws -> [QuotaUpdate] {
        // 토큰 형식: "<userId>%3A%3A<jwt>" — 앞부분이 userId
        let decoded = token.removingPercentEncoding ?? token
        let userId = decoded.components(separatedBy: "::").first ?? ""
        guard var components = URLComponents(string: "https://cursor.com/api/usage") else {
            throw ConnectorError.network("URL 오류")
        }
        components.queryItems = [URLQueryItem(name: "user", value: userId)]
        guard let url = components.url else { throw ConnectorError.network("URL 오류") }

        let (data, code) = try await HTTP.get(url, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
        ])
        switch code {
        case 200: break
        case 401, 403: throw ConnectorError.unauthorized
        default: throw ConnectorError.network("HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpt4 = json["gpt-4"] as? [String: Any] else {
            throw ConnectorError.schemaChanged("gpt-4 필드 없음")
        }

        let used = (gpt4["numRequests"] as? NSNumber)?.doubleValue ?? 0
        let cap = (gpt4["maxRequestUsage"] as? NSNumber)?.doubleValue
        var resetsAt: Date?
        if let start = DateParsing.iso8601(json["startOfMonth"] as? String) {
            resetsAt = Calendar.current.date(byAdding: .month, value: 1, to: start)
        }
        return [QuotaUpdate(key: "fast_requests", name: "프리미엄 요청",
                            used: used, cap: cap, unit: "회", resetsAt: resetsAt)]
    }

    // MARK: - /api/dashboard/get-monthly-invoice

    private func fetchMonthlyInvoice(cookie: String) async throws -> QuotaUpdate? {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        guard let url = URL(string: "https://cursor.com/api/dashboard/get-monthly-invoice") else {
            return nil
        }
        let (data, code) = try await HTTP.post(url, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
        ], jsonBody: [
            "month": comps.month ?? 1,
            "year": comps.year ?? 2026,
            "includeUsageEvents": false,
        ])
        switch code {
        case 200: break
        case 401, 403: throw ConnectorError.unauthorized
        default: throw ConnectorError.network("HTTP \(code)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw ConnectorError.schemaChanged("items 필드 없음")
        }

        let totalCents = items.reduce(0.0) { sum, item in
            sum + ((item["cents"] as? NSNumber)?.doubleValue ?? 0)
        }
        return QuotaUpdate(key: "included_usage", name: "포함 사용량",
                           used: totalCents / 100.0, cap: nil, unit: "$",
                           resetsAt: nil, planName: PlanDetection.from(json: json))
    }
}
