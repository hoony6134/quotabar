import Foundation

/// Gemini — Google이 앱 잔량 API를 공개하지 않기 때문에 ~/.gemini 로컬 기록을 읽어
/// 최근 활동량을 자동 추정한다. 서버가 계산하는 실제 compute quota와는 다를 수 있다.
struct GeminiConnector: QuotaConnector {
    static let autoSentinel = "auto:gemini-local"

    func fetch(credential: String) async throws -> [QuotaUpdate] {
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

        return [
            QuotaUpdate(key: "gemini_5h", name: "Gemini 활동 (5시간)",
                        used: fiveHourCount, cap: 100, unit: "회",
                        resetsAt: now.addingTimeInterval(5 * 3600), planName: "AI Pro"),
            QuotaUpdate(key: "gemini_day", name: "Gemini 활동 (오늘)",
                        used: dayCount, cap: 100, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .day, value: 1, to: dayStart),
                        planName: "AI Pro"),
            QuotaUpdate(key: "gemini_deep_research", name: "Deep Research",
                        used: researchCount, cap: 20, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .day, value: 1, to: dayStart),
                        planName: "AI Pro"),
        ]
    }
}
