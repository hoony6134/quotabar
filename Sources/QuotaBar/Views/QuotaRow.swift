import SwiftUI

/// 쿼터 한 줄: 이름 · 게이지 · 사용량 · 리셋 카운트다운
struct QuotaRow: View {
    @EnvironmentObject var store: AppStore
    let accountID: UUID
    let item: QuotaItem
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.def.name)
                    .font(compact ? .caption : .callout)
                    .lineLimit(1)
                if item.def.apiSynced {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: compact ? 8 : 9))
                        .foregroundStyle(.tertiary)
                        .help("API 자동 동기화")
                }
                Spacer()
                Text("\(Int((item.utilization * 100).rounded()))%")
                    .font((compact ? Font.caption : Font.callout).bold())
                    .monospacedDigit()
                    .foregroundStyle(QuotaTheme.levelColor(utilization: item.utilization))
                if item.def.unit != "%" {
                    Text(Fmt.usageLine(item))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            GaugeBar(utilization: item.utilization, height: compact ? 5 : 7)
            ResetCountdown(resetsAt: item.resetsAt, periodLabel: item.def.period.label)
        }
    }
}
