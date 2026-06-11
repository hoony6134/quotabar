import SwiftUI
import AppKit

// MARK: - Liquid Glass

private struct QuotaGlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.7)
                }
        }
    }
}

private struct QuotaGlassButtonModifier: ViewModifier {
    var prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

extension View {
    func quotaGlassSurface(cornerRadius: CGFloat = 12, interactive: Bool = false) -> some View {
        modifier(QuotaGlassSurfaceModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    func quotaGlassButton(prominent: Bool = false) -> some View {
        modifier(QuotaGlassButtonModifier(prominent: prominent))
    }
}

// MARK: - 게이지 바

struct GaugeBar: View {
    let utilization: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(UtilizationLevel.color(utilization))
                    .frame(width: max(geo.size.width * utilization, utilization > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: utilization)
    }
}

// MARK: - 리셋 카운트다운

struct ResetCountdown: View {
    let resetsAt: Date?
    let periodLabel: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(text(now: context.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        guard let resetsAt else { return periodLabel }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "\(periodLabel) · 리셋됨" }
        return "\(periodLabel) · \(Self.format(remaining)) 후 리셋"
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }
}

// MARK: - 세션 리셋 시간

struct QuotaResetSummary: View {
    let resetsAt: Date?
    let periodLabel: String
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Label(text(now: context.date), systemImage: "timer")
            .font(compact ? .caption2 : .caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func text(now: Date) -> String {
        guard let resetsAt else {
            return periodLabel.isEmpty ? "리셋 시간 없음" : "\(periodLabel) 리셋 시간 없음"
        }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "곧 리셋" }
        let prefix = periodLabel.isEmpty ? "" : "\(periodLabel) · "
        return "\(prefix)\(ResetCountdown.format(remaining)) 후 리셋"
    }
}

// MARK: - 서비스 아이콘 배지

struct ServiceBadge: View {
    let service: ServiceKind
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let logo = ServiceLogo.image(for: service) {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size * 0.62, height: size * 0.62)
            } else {
                Image(systemName: service.symbolName)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(service.brandColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

/// 번들에 포함된 실제 제품 로고 (흰색 PNG, Resources/Logos/<rawValue>.png)
enum ServiceLogo {
    private static var cache: [ServiceKind: NSImage] = [:]

    /// SPM 빌드(리소스 번들)와 Xcode 빌드(Bundle.main) 모두 지원.
    /// Bundle.module은 번들이 없으면 fatalError로 앱을 죽이므로 직접 탐색한다.
    private static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        let bundleName = "QuotaBar_QuotaBar.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,                                    // .app/Contents/Resources/
            Bundle.main.executableURL?.deletingLastPathComponent(),     // 바이너리 옆 (.build/release/)
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent(bundleName),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .main
        #else
        return .main
        #endif
    }()

    private static var templateCache: [ServiceKind: NSImage] = [:]

    /// 메뉴막대용 템플릿(단색) 로고 — 다크/라이트 메뉴막대에 자동 적응.
    /// MenuBarExtra 라벨은 SwiftUI frame을 무시하고 NSImage 고유 크기로 그리므로
    /// 여기서 포인트 크기를 메뉴막대에 맞게 직접 지정한다.
    static func templateImage(for service: ServiceKind) -> NSImage? {
        if let cached = templateCache[service] { return cached }
        guard let original = image(for: service),
              let copy = original.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 15, height: 15)
        copy.isTemplate = true
        templateCache[service] = copy
        return copy
    }

    static func image(for service: ServiceKind) -> NSImage? {
        if let cached = cache[service] { return cached }
        let candidates = [
            resourceBundle.url(forResource: service.rawValue, withExtension: "png",
                               subdirectory: "Logos"),
            resourceBundle.url(forResource: service.rawValue, withExtension: "png"),
        ]
        for url in candidates {
            if let url, let image = NSImage(contentsOf: url) {
                cache[service] = image
                return image
            }
        }
        return nil
    }
}

// MARK: - 숫자 포맷

enum Fmt {
    static func quantity(_ value: Double, unit: String) -> String {
        let number: String
        if value.rounded() == value && abs(value) < 100_000 {
            number = String(Int(value))
        } else {
            number = String(format: "%.2f", value)
        }
        switch unit {
        case "$": return "$\(number)"
        case "%": return "\(number)%"
        default:  return unit.isEmpty ? number : "\(number)\(unit)"
        }
    }

    static func usageLine(_ item: QuotaItem) -> String {
        "\(quantity(item.state.used, unit: item.def.unit)) / \(quantity(item.def.cap, unit: item.def.unit))"
    }
}
