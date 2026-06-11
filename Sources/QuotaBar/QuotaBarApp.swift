import SwiftUI
import AppKit

@main
struct QuotaBarApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        // 메인 대시보드 윈도우
        Window("QuotaBar 대시보드", id: "dashboard") {
            DashboardView()
                .environmentObject(store)
        }
        .defaultSize(width: 640, height: 720)

        // 메뉴막대
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("새로고침") {
                    Task { await store.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // 설정 (⌘,)
        Settings {
            AppSettingsView()
                .environmentObject(store)
        }
    }
}
