import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#endif

/// QuotaBar 2.0 디자인 토큰 — macOS 앱/위젯, iOS 앱/위젯 공통.
enum QuotaTheme {
    // 사용률 단계 (퍼센트 0...100). 다크/라이트 모두에서 대비가 나오는 채도 높은 톤.
    static let ok       = Color(red: 0.24, green: 0.82, blue: 0.58)   // 민트
    static let caution  = Color(red: 1.00, green: 0.77, blue: 0.26)   // 앰버
    static let high     = Color(red: 1.00, green: 0.54, blue: 0.24)   // 오렌지
    static let critical = Color(red: 1.00, green: 0.30, blue: 0.37)   // 레드

    static func levelColor(percent: Double) -> Color {
        switch percent {
        case ..<50:  return ok
        case ..<75:  return caution
        case ..<90:  return high
        default:     return critical
        }
    }

    static func levelColor(utilization: Double) -> Color {
        levelColor(percent: utilization * 100)
    }

    /// 접근성용 상태 문구 (색에만 의존하지 않는다)
    static func levelLabel(percent: Double) -> String {
        switch percent {
        case ..<50:  return "여유"
        case ..<75:  return "보통"
        case ..<90:  return "주의"
        default:     return "임박"
        }
    }

    static func gradient(percent: Double) -> LinearGradient {
        let c = levelColor(percent: percent)
        return LinearGradient(colors: [c.opacity(0.75), c], startPoint: .leading, endPoint: .trailing)
    }

    /// 앱 배경 — 다크 우선의 은은한 그라데이션
    static let backdropTop    = Color(red: 0.07, green: 0.08, blue: 0.12)
    static let backdropBottom = Color(red: 0.03, green: 0.04, blue: 0.07)
}

extension Color {
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255.0,
                  green: Double((value >> 8) & 0xFF) / 255.0,
                  blue: Double(value & 0xFF) / 255.0)
    }
}

// MARK: - 시간 표기

enum QuotaFormat {
    static func remaining(_ interval: TimeInterval) -> String {
        let total = max(Int(interval), 0)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(max(minutes, 1))분"
    }

    static func resetText(_ item: WidgetQuotaItem, now: Date = Date(), withPeriod: Bool = true) -> String {
        let prefix = (withPeriod ? item.periodLabel.map { "\($0) · " } : nil) ?? ""
        guard let resetsAt = item.resetsAt else { return prefix + "리셋 정보 없음" }
        let left = resetsAt.timeIntervalSince(now)
        if left <= 0 { return prefix + "곧 리셋" }
        return "\(prefix)\(remaining(left)) 후 리셋"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(Int(now.timeIntervalSince(date)), 0)
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }
}

// MARK: - 서비스 로고 / 배지 (플랫폼 공통)

enum SharedLogo {
    private static var cache: [String: PlatformImage] = [:]

    static func image(for serviceID: String?) -> PlatformImage? {
        guard let serviceID, !serviceID.isEmpty else { return nil }
        if let cached = cache[serviceID] { return cached }
        var bundles: [Bundle] = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        bundles.append(Bundle(for: BundleToken.self))
        let url = bundles.lazy.compactMap { bundle in
            bundle.url(forResource: serviceID, withExtension: "png", subdirectory: "Logos")
                ?? bundle.url(forResource: serviceID, withExtension: "png")
        }.first
        guard let url, let image = PlatformImage(contentsOfFile: url.path) else { return nil }
        cache[serviceID] = image
        return image
    }

    static func symbol(for serviceID: String?) -> String {
        switch serviceID {
        case "claude": return "sparkle"
        case "chatgpt": return "bubble.left.and.bubble.right.fill"
        case "googleAI": return "diamond.fill"
        case "antigravity": return "atom"
        case "cursor": return "cursorarrow.rays"
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkle"
        }
    }

    private final class BundleToken {}
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// 브랜드 색 배경 + 흰색 제품 로고 배지
struct ServiceMark: View {
    let serviceID: String?
    let colorHex: String?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let logo = SharedLogo.image(for: serviceID) {
                Image(platformImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                Image(systemName: SharedLogo.symbol(for: serviceID))
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background((Color(hex: colorHex) ?? .gray).gradient,
                    in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - 링 / 바

/// 그라데이션 링 게이지. 중앙 콘텐츠는 호출자가 채운다.
struct QuotaRing<Center: View>: View {
    let percent: Double
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: () -> Center

    var body: some View {
        let p = min(max(percent, 0), 100) / 100
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(p, p > 0 ? 0.015 : 0))
                .stroke(
                    AngularGradient(
                        colors: [QuotaTheme.levelColor(percent: percent).opacity(0.55),
                                 QuotaTheme.levelColor(percent: percent)],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * p)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
    }
}

/// 가로 바 게이지
struct QuotaBarGauge: View {
    let percent: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let p = min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(QuotaTheme.gradient(percent: percent))
                    .frame(width: max(geo.size.width * p, p > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 표시 시점 보정

extension WidgetQuotaItem {
    /// 리셋 시각이 지났는데 새 데이터가 없으면 롤링 윈도우는 비어 있는 상태이므로 0%로 본다.
    func effectivePercent(at date: Date = Date()) -> Double {
        if let resetsAt, resetsAt <= date { return 0 }
        return min(max(percent, 0), 100)
    }

    var isResetPassed: Bool {
        if let resetsAt { return resetsAt <= Date() }
        return false
    }
}

extension WidgetSnapshot {
    /// Mac이 꺼져 있거나 잠자기라 데이터가 오래된 경우
    func isStale(at date: Date = Date(), after minutes: Double = 45) -> Bool {
        date.timeIntervalSince(generatedAt) > minutes * 60
    }
}
