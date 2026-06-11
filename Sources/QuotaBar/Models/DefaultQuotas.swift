import Foundation

/// 서비스별 기본 쿼터 카탈로그 (2026-06 기준 공개 정보).
/// 정확한 수치는 서비스가 수시로 바꾸므로, 계정 상세 화면에서 자유롭게 수정할 수 있다.
enum DefaultQuotas {

    static func quotas(for service: ServiceKind) -> [QuotaItem] {
        switch service {

        case .claude:
            // /api/oauth/usage 가 utilization(%)만 제공하므로 cap=100(%) 기준
            return [
                item(key: "five_hour",     name: "세션 (5시간)",      cap: 100, unit: "%", period: .rollingHours(5), api: true),
                item(key: "seven_day",     name: "주간 (전체 모델)",  cap: 100, unit: "%", period: .rollingDays(7),  api: true),
                item(key: "seven_day_opus", name: "주간 (Opus)",      cap: 100, unit: "%", period: .rollingDays(7),  api: true),
            ]

        case .chatgpt:
            // Codex는 ChatGPT 플랜에 묶인 5시간/주간 레인 사용률을 반환한다.
            return [
                item(key: "codex_primary",   name: "Codex 세션 (5시간)", cap: 100, unit: "%", period: .rollingHours(5), api: true),
                item(key: "codex_secondary", name: "Codex 주간",        cap: 100, unit: "%", period: .rollingDays(7),  api: true),
            ]

        case .googleAI:
            // Gemini 앱은 서버 잔량 API가 없어서 로컬 Gemini 기록 기반 활동량으로 자동 추정한다.
            return [
                item(key: "gemini_5h",        name: "Gemini 활동 (5시간)", cap: 100, unit: "회", period: .rollingHours(5), api: true),
                item(key: "gemini_day",       name: "Gemini 활동 (오늘)",  cap: 100, unit: "회", period: .daily,           api: true),
                item(key: "gemini_deep_research", name: "Deep Research",  cap: 20,  unit: "회", period: .daily,           api: true),
            ]

        case .antigravity:
            // Antigravity는 로컬 대화/에이전트 상태 파일의 최근 갱신량을 자동 추정한다.
            return [
                item(key: "antigravity_5h",   name: "Agent 활동 (5시간)", cap: 100, unit: "회", period: .rollingHours(5), api: true),
                item(key: "antigravity_day",  name: "Agent 활동 (오늘)",  cap: 100, unit: "회", period: .daily,           api: true),
                item(key: "antigravity_month", name: "Agent 활동 (월간)", cap: 1000, unit: "회", period: .monthly(day: 1), api: true),
            ]

        case .cursor:
            // Pro: 월 $20 상당 포함 사용량 (달러 기준)
            return [
                item(key: "included_usage", name: "포함 사용량",      cap: 20,  unit: "$",  period: .monthly(day: 1), api: true),
            ]

        case .copilot:
            // Edu(=Pro 무료): 프리미엄 요청 300/월, 채팅·자동완성 무제한
            return [
                item(key: "premium_requests", name: "프리미엄 요청",  cap: 300, unit: "회", period: .monthly(day: 1), api: true),
            ]

        case .nvidiaNIM:
            return []
        }
    }

    private static func item(key: String, name: String, cap: Double, unit: String,
                             period: ResetPeriod, api: Bool) -> QuotaItem {
        QuotaItem(def: QuotaDef(key: key, name: name, cap: cap, unit: unit,
                                period: period, apiSynced: api))
    }
}
