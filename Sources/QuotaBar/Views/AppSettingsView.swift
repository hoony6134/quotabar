import SwiftUI

/// 전역 설정 (⌘,)
struct AppSettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section("동기화") {
                Picker("자동 새로고침 주기", selection: $store.refreshIntervalMinutes) {
                    Text("1분").tag(1)
                    Text("5분").tag(5)
                    Text("10분").tag(10)
                    Text("30분").tag(30)
                }
            }
            Section("표시") {
                Toggle("Dock 아이콘 숨기기 (메뉴막대 전용)", isOn: $store.hideDockIcon)
                Picker("메뉴막대 퍼센트", selection: $store.menuBarQuotaSelection) {
                    ForEach(store.menuBarQuotaOptions) { option in
                        Text("\(option.title) · \(option.percentage)%").tag(option.id)
                    }
                }
            }
            Section("알림") {
                Toggle("세션 초기화 시 알림 받기", isOn: $store.enableResetNotifications)
            }
            Section {
                Text("Claude·Codex·Cursor·Copilot은 비공식 사용량 엔드포인트를 사용합니다. Gemini·Antigravity는 공개 잔량 API가 없어 로컬 기록 기반 활동량으로 자동 추정합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
