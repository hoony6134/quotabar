import Foundation
import SwiftUI

// MARK: - 서비스 종류

enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case claude
    case chatgpt
    case googleAI
    case antigravity
    case cursor
    case copilot
    case nvidiaNIM

    static var allCases: [ServiceKind] {
        [.claude, .chatgpt, .googleAI, .antigravity, .cursor, .copilot]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:    return "Claude"
        case .chatgpt:   return "ChatGPT"
        case .googleAI:  return "Gemini"
        case .antigravity: return "Antigravity"
        case .cursor:    return "Cursor"
        case .copilot:   return "GitHub Copilot"
        case .nvidiaNIM: return "NVIDIA NIM"
        }
    }

    var brandColor: Color {
        switch self {
        case .claude:    return Color(red: 0.85, green: 0.47, blue: 0.34) // 테라코타
        case .chatgpt:   return Color(red: 0.10, green: 0.65, blue: 0.55) // 청록
        case .googleAI:  return Color(red: 0.26, green: 0.52, blue: 0.96) // 파랑
        case .antigravity: return Color(red: 0.88, green: 0.28, blue: 0.40) // 장미
        case .cursor:    return Color(red: 0.45, green: 0.40, blue: 0.95) // 보라
        case .copilot:   return Color(red: 0.45, green: 0.55, blue: 0.65) // 회청
        case .nvidiaNIM: return Color(red: 0.46, green: 0.73, blue: 0.00) // 초록
        }
    }

    /// brandColor와 동일한 색의 hex — 위젯 스냅샷에 실어 보낸다
    var brandHex: String {
        switch self {
        case .claude:    return "D97857"
        case .chatgpt:   return "1AA68C"
        case .googleAI:  return "4285F5"
        case .antigravity: return "E04766"
        case .cursor:    return "7366F2"
        case .copilot:   return "738CA6"
        case .nvidiaNIM: return "75BA00"
        }
    }

    var symbolName: String {
        switch self {
        case .claude:    return "sparkle"
        case .chatgpt:   return "bubble.left.and.bubble.right.fill"
        case .googleAI:  return "diamond.fill"
        case .antigravity: return "atom"
        case .cursor:    return "cursorarrow.rays"
        case .copilot:   return "chevron.left.forwardslash.chevron.right"
        case .nvidiaNIM: return "cpu.fill"
        }
    }

    /// API 자동 연동을 지원하는 서비스인지
    var supportsAPISync: Bool {
        switch self {
        case .claude, .chatgpt, .googleAI, .antigravity, .cursor, .copilot: return true
        case .nvidiaNIM: return false
        }
    }

    var autoCredentialSentinel: String? {
        switch self {
        case .claude: return ClaudeConnector.autoSentinel
        case .chatgpt: return ChatGPTConnector.autoSentinel
        case .googleAI: return GeminiConnector.autoSentinel
        case .antigravity: return AntigravityConnector.autoSentinel
        case .cursor, .copilot, .nvidiaNIM: return nil
        }
    }

    /// 인증 입력 안내문
    var authHint: String {
        switch self {
        case .claude:
            return "'자동 감지'는 Claude Code 자격증명을 저장하지 않고 매 갱신마다 다시 읽습니다. 파일을 먼저 보고, 키체인은 확인 창 없이 접근 가능한 항목만 조용히 조회합니다."
        case .chatgpt:
            return "'자동 감지'는 Codex 자격증명(~/.codex/auth.json)을 실시간으로 읽어 Codex 5시간/주간 한도를 조회합니다."
        case .googleAI:
            return "'자동 감지'는 Gemini 로컬 기록(~/.gemini)을 읽어 최근 활동량을 추정합니다. Google이 서버 잔량 API를 공개하지 않아 실제 잔여량과 다를 수 있습니다."
        case .antigravity:
            return "'자동 감지'는 Antigravity 로컬 상태(~/.gemini/antigravity)를 읽어 최근 에이전트 활동량을 추정합니다."
        case .cursor:
            return "cursor.com 로그인 후 브라우저 개발자도구 → Cookies → WorkosCursorSessionToken 값을 붙여넣으세요."
        case .copilot:
            return "GitHub Personal Access Token (Copilot 사용 계정, 'read:user' 권한이면 충분)."
        case .nvidiaNIM:
            return "자동으로 읽을 수 있는 로컬 기록이나 사용량 API가 없어 기본 목록에서 제외했습니다."
        }
    }
}

// MARK: - 리셋 주기

enum ResetPeriod: Codable, Hashable {
    /// 첫 사용 시점부터 n시간 롤링 윈도우 (예: Claude 5시간 세션, ChatGPT 3시간)
    case rollingHours(Int)
    /// 첫 사용 시점부터 n일 롤링 윈도우 (예: 주간 한도)
    case rollingDays(Int)
    /// 매일 자정(로컬) 리셋
    case daily
    /// 매월 지정일 리셋 (구독 갱신일)
    case monthly(day: Int)
    /// 리셋 없음 (누적 크레딧 등)
    case never

    var label: String {
        switch self {
        case .rollingHours(let h): return "\(h)시간"
        case .rollingDays(let d):  return d == 7 ? "주간" : "\(d)일"
        case .daily:               return "일간"
        case .monthly:             return "월간"
        case .never:               return "누적"
        }
    }

    /// anchor(첫 사용 시점) 기준 다음 리셋 시각
    func nextReset(anchor: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .rollingHours(let h):
            guard let anchor else { return nil }
            return anchor.addingTimeInterval(TimeInterval(h) * 3600)
        case .rollingDays(let d):
            guard let anchor else { return nil }
            return anchor.addingTimeInterval(TimeInterval(d) * 86400)
        case .daily:
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: startOfToday)
        case .monthly(let day):
            var comps = calendar.dateComponents([.year, .month], from: now)
            comps.day = min(max(day, 1), 28)
            guard let thisMonth = calendar.date(from: comps) else { return nil }
            if thisMonth > now { return thisMonth }
            return calendar.date(byAdding: .month, value: 1, to: thisMonth)
        case .never:
            return nil
        }
    }
}

// MARK: - 쿼터 정의 + 상태

struct QuotaDef: Codable, Hashable, Identifiable {
    /// 커넥터가 갱신할 때 매칭하는 안정적 키 (예: "five_hour", "premium_requests")
    var key: String
    var name: String
    var cap: Double
    var unit: String
    var period: ResetPeriod
    /// true면 자동 동기화 대상, false면 레거시 로컬 상태
    var apiSynced: Bool

    var id: String { key }
}

struct QuotaState: Codable, Hashable {
    var used: Double = 0
    /// 롤링 윈도우의 시작(첫 사용) 시점
    var anchor: Date?
    /// API가 알려준 리셋 시각 (있으면 우선 사용)
    var apiResetsAt: Date?
    var lastSynced: Date?
}

struct QuotaItem: Codable, Hashable, Identifiable {
    var def: QuotaDef
    var state: QuotaState = QuotaState()

    var id: String { def.key }

    var utilization: Double {
        guard def.cap > 0, state.used.isFinite else { return 0 }
        return min(max(state.used / def.cap, 0), 1)
    }

    var resetsAt: Date? {
        state.apiResetsAt ?? def.period.nextReset(anchor: state.anchor)
    }
}

// MARK: - 계정

struct Account: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var service: ServiceKind
    /// 사용자 지정 라벨 (예: "개인", "회사 계정")
    var label: String
    /// API 동기화 사용 여부 (지원 서비스에서 끌 수도 있음)
    var apiSyncEnabled: Bool
    var quotas: [QuotaItem]
    var lastSyncError: String?
    var lastSyncAt: Date?
    var detectedPlanName: String?

    /// 가장 높은 사용률 (대시보드/메뉴막대 요약용)
    var worstUtilization: Double {
        quotas.map(\.utilization).max() ?? 0
    }
}

// MARK: - 메뉴막대 표시 옵션

struct MenuBarQuotaOption: Identifiable, Hashable {
    static let worstID = "worst"

    var id: String
    var service: ServiceKind?
    var title: String
    var subtitle: String
    var utilization: Double
    var resetsAt: Date?
    var periodLabel: String

    var percentage: Int {
        Int((utilization * 100).rounded())
    }
}

// MARK: - 사용률 → 색상

enum UtilizationLevel {
    static func color(_ value: Double) -> Color {
        switch value {
        case ..<0.5:  return .green
        case ..<0.75: return .yellow
        case ..<0.9:  return .orange
        default:      return .red
        }
    }
}
