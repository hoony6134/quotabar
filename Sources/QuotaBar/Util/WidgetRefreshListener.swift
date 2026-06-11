import Foundation

final class WidgetRefreshListener: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func handleNotification(_ notification: Notification) {
        handler()
    }
}
