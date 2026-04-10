import AppKit
import UserNotifications

/// Posts a macOS notification when a download finishes. Clicking the
/// notification reveals the file in Finder.
@MainActor
final class DownloadNotifier: NSObject {
    static let shared = DownloadNotifier()

    private var authorized = false
    private var authRequested = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategory()
    }

    // MARK: - Authorization

    /// Lazy authorization request — runs on the first notification the app
    /// tries to send, so the user isn't prompted before they've actually
    /// started a download.
    func requestAuthorizationIfNeeded() async {
        guard !authRequested else { return }
        authRequested = true
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            authorized = false
        }
    }

    private func registerCategory() {
        let reveal = UNNotificationAction(
            identifier: "REVEAL_FILE",
            title: Localization.shared.str(.notificationRevealAction),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "DOWNLOAD_DONE",
            actions: [reveal],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Posting

    func notifyDownloadComplete(title: String, filePath: String?) {
        Task { [weak self] in
            guard let self else { return }
            await self.requestAuthorizationIfNeeded()
            guard self.authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = Localization.shared.str(.notificationDoneBody)
            content.sound = .default
            content.categoryIdentifier = "DOWNLOAD_DONE"
            if let filePath {
                content.userInfo = ["filePath": filePath]
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil  // deliver immediately
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Delegate (foreground display + click handling)

extension DownloadNotifier: UNUserNotificationCenterDelegate {

    /// Called while the app is in the foreground. Without this the
    /// notification would be silently suppressed because macOS assumes
    /// the user already sees what's happening inside the window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Called when the user clicks the notification or one of its actions.
    /// We always reveal the file in Finder, whether they tapped the body
    /// or the explicit "Show in Finder" action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let path = userInfo["filePath"] as? String {
            let url = URL(fileURLWithPath: path)
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        completionHandler()
    }
}
