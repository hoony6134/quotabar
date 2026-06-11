import Foundation

/// Antigravity — 로컬 대화/implicit 상태 파일의 갱신 시각으로 에이전트 활동량을 추정한다.
/// 공식 잔량 API가 없어서 "최근 로컬 활동" 지표로 자동화한다.
struct AntigravityConnector: QuotaConnector {
    static let autoSentinel = "auto:antigravity-local"

    func fetch(credential: String) async throws -> [QuotaUpdate] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".gemini/antigravity")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ConnectorError.hint("Antigravity 로컬 상태(~/.gemini/antigravity)를 찾지 못했습니다. Antigravity를 한 번 실행한 뒤 다시 시도하세요.")
        }

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let dayStart = LocalActivity.startOfToday()
        let monthStart = LocalActivity.startOfMonth()
        let roots = [
            root.appendingPathComponent("conversations"),
            root.appendingPathComponent("implicit"),
            root.appendingPathComponent("annotations"),
        ]

        let fiveHourCount = LocalActivity.countModifiedFiles(roots: roots, since: fiveHoursAgo, extensions: ["pb", "pbtxt"])
        let dayCount = LocalActivity.countModifiedFiles(roots: roots, since: dayStart, extensions: ["pb", "pbtxt"])
        let monthCount = LocalActivity.countModifiedFiles(roots: roots, since: monthStart, extensions: ["pb", "pbtxt"])

        return [
            QuotaUpdate(key: "antigravity_5h", name: "Agent 활동 (5시간)",
                        used: fiveHourCount, cap: 100, unit: "회",
                        resetsAt: now.addingTimeInterval(5 * 3600), planName: "AI Pro"),
            QuotaUpdate(key: "antigravity_day", name: "Agent 활동 (오늘)",
                        used: dayCount, cap: 100, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .day, value: 1, to: dayStart),
                        planName: "AI Pro"),
            QuotaUpdate(key: "antigravity_month", name: "Agent 활동 (월간)",
                        used: monthCount, cap: 1000, unit: "회",
                        resetsAt: Calendar.current.date(byAdding: .month, value: 1, to: monthStart),
                        planName: "AI Pro"),
        ]
    }
}
