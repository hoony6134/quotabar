import Foundation

/// Cursor — 대시보드가 쓰는 비공식 API (쿠키 인증).
///
/// 인증 (우선순위):
/// 1. 직접 붙여넣은 `WorkosCursorSessionToken` 값 (또는 `Cookie:` 헤더 통째로)
/// 2. `auto:cursor-app` 센티널 — 설치된 Cursor.app 로그인 상태(`state.vscdb`의 accessToken)에서
///    쿠키를 조립한다. 읽기 전용이며 토큰을 갱신하거나 저장하지 않는다.
///
/// 조회 (모두 시도해 파싱되는 것만 반영):
/// - `GET /api/usage-summary` — 최신 요금제: 포함 사용량·온디맨드 사용량·청구 주기
/// - `GET /api/usage?user=ID` — 레거시 요청 횟수 기반 플랜
/// - `POST /api/dashboard/get-monthly-invoice` — 마지막 폴백 (이번 달 과금 합계)
struct CursorConnector: QuotaConnector {
    static let autoSentinel = "auto:cursor-app"

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let resolved = try Self.resolveCookie(credential)
        var updates: [QuotaUpdate] = []
        var lastError: Error?

        // 1) 최신: usage-summary
        do {
            updates.append(contentsOf: try await fetchUsageSummary(cookie: resolved.cookie))
        } catch { lastError = error }

        // 2) 레거시 요청 횟수 (summary에 포함 한도가 없을 때만)
        if updates.isEmpty {
            do {
                updates.append(contentsOf: try await fetchLegacyUsage(cookie: resolved.cookie,
                                                                      userId: resolved.userId))
            } catch { lastError = error }
        }

        // 3) 인보이스 합계 (그래도 비었을 때)
        if updates.isEmpty {
            do {
                if let update = try await fetchMonthlyInvoice(cookie: resolved.cookie) {
                    updates.append(update)
                }
            } catch { lastError = error }
        }

        if updates.isEmpty {
            throw lastError ?? ConnectorError.schemaChanged("사용 가능한 엔드포인트 없음")
        }
        return updates
    }

    // MARK: - 인증 해석

    private struct Resolved {
        var cookie: String
        var userId: String
    }

    private static func resolveCookie(_ credential: String) throws -> Resolved {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectorError.noCredential }

        if trimmed == autoSentinel {
            guard let app = detectAppToken() else {
                throw ConnectorError.hint("Cursor 앱 로그인 정보를 찾지 못했습니다. Cursor를 실행해 로그인하거나, 계정 설정에서 WorkosCursorSessionToken 쿠키를 직접 붙여넣으세요.")
            }
            return app
        }

        // "Cookie: a=b; WorkosCursorSessionToken=…" 통째로 붙여넣은 경우
        if trimmed.contains("=") {
            let headerValue = trimmed.hasPrefix("Cookie:") ? String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces) : trimmed
            let token = headerValue.components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("WorkosCursorSessionToken=") }
                .map { String($0.dropFirst("WorkosCursorSessionToken=".count)) }
            if let token { return Resolved(cookie: "WorkosCursorSessionToken=\(token)", userId: userId(fromToken: token)) }
            return Resolved(cookie: headerValue, userId: "")
        }
        return Resolved(cookie: "WorkosCursorSessionToken=\(trimmed)", userId: userId(fromToken: trimmed))
    }

    /// 토큰 형식: "<userId>%3A%3A<jwt>"
    private static func userId(fromToken token: String) -> String {
        let decoded = token.removingPercentEncoding ?? token
        return decoded.components(separatedBy: "::").first ?? ""
    }

    // MARK: - Cursor.app 로그인 상태 읽기

    /// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`의 `cursorAuth/accessToken`.
    /// 시스템 `sqlite3`를 읽기 전용으로 호출한다 (DB를 수정하지 않음).
    private static func detectAppToken() -> Resolved? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", db.path,
                             "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken' LIMIT 1;"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let jwt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              jwt.split(separator: ".").count >= 3,
              let claims = ChatGPTConnector.jwtClaims(jwt) else { return nil }

        // 만료 60초 전이면 사용하지 않는다 (갱신은 Cursor 앱 몫)
        if let exp = (claims["exp"] as? NSNumber)?.doubleValue,
           Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(60) { return nil }

        // sub: "auth0|user_01ABC…" 또는 "google-oauth2|user_…" → 파이프 뒤가 userId
        guard let sub = claims["sub"] as? String else { return nil }
        let userId = sub.components(separatedBy: "|").last ?? sub
        return Resolved(cookie: "WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)", userId: userId)
    }

    // MARK: - /api/usage-summary (최신)

    private func fetchUsageSummary(cookie: String) async throws -> [QuotaUpdate] {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw ConnectorError.network("URL 오류")
        }
        let (data, code) = try await HTTP.get(url, headers: Self.headers(cookie))
        switch code {
        case 200: break
        case 401, 403: throw ConnectorError.unauthorized
        case 429: throw ConnectorError.rateLimited
        default: throw ConnectorError.network("HTTP \(code)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError.schemaChanged("JSON 아님")
        }

        let resetsAt = DateParsing.iso8601(json["billingCycleEnd"] as? String)
        let plan = PlanDetection.normalize(json["membershipType"] as? String)
        let individual = json["individualUsage"] as? [String: Any]
        var updates: [QuotaUpdate] = []

        // 포함 사용량 (센트 → 달러). totalPercentUsed가 있으면 우선.
        if let planUsage = individual?["plan"] as? [String: Any] {
            let usedCents = Self.number(planUsage["used"])
            let limitCents = Self.number(planUsage["limit"])
            if let limitCents, limitCents > 0 {
                updates.append(QuotaUpdate(key: "included_usage", name: "포함 사용량",
                                           used: (usedCents ?? 0) / 100, cap: limitCents / 100, unit: "$",
                                           resetsAt: resetsAt, planName: plan))
            } else if let pct = Self.number(planUsage["totalPercentUsed"]) {
                updates.append(QuotaUpdate(key: "included_usage", name: "포함 사용량",
                                           used: pct, cap: 100, unit: "%",
                                           resetsAt: resetsAt, planName: plan))
            }
        }

        // 온디맨드(초과 사용량) — 한도가 있을 때만 쿼터로 표시
        if let onDemand = individual?["onDemand"] as? [String: Any],
           (onDemand["enabled"] as? Bool) ?? true,
           let limitCents = Self.number(onDemand["limit"]), limitCents > 0 {
            updates.append(QuotaUpdate(key: "on_demand", name: "온디맨드 사용량",
                                       used: (Self.number(onDemand["used"]) ?? 0) / 100,
                                       cap: limitCents / 100, unit: "$",
                                       resetsAt: resetsAt, planName: plan))
        }

        guard !updates.isEmpty else { throw ConnectorError.schemaChanged("individualUsage.plan 없음") }
        return updates
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func headers(_ cookie: String) -> [String: String] {
        ["Cookie": cookie, "Accept": "application/json", "Origin": "https://cursor.com"]
    }

    // MARK: - 레거시 /api/usage

    private func fetchLegacyUsage(cookie: String, userId: String) async throws -> [QuotaUpdate] {
        guard var components = URLComponents(string: "https://cursor.com/api/usage") else {
            throw ConnectorError.network("URL 오류")
        }
        components.queryItems = [URLQueryItem(name: "user", value: userId)]
        guard let url = components.url else { throw ConnectorError.network("URL 오류") }

        let (data, code) = try await HTTP.get(url, headers: Self.headers(cookie))
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

    // MARK: - /api/dashboard/get-monthly-invoice (최후 폴백)

    private func fetchMonthlyInvoice(cookie: String) async throws -> QuotaUpdate? {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        guard let url = URL(string: "https://cursor.com/api/dashboard/get-monthly-invoice") else {
            return nil
        }
        let (data, code) = try await HTTP.post(url, headers: Self.headers(cookie), jsonBody: [
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
