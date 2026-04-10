import AppKit
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController.
///
/// Sparkle is initialised with `startingUpdater: false`, then we call
/// `start()` ourselves inside a try/catch so we can swallow start-up
/// errors silently. Otherwise Sparkle's default user driver would pop
/// an "Updater failed to start" dialog every launch before the user has
/// configured a real appcast URL + EdDSA public key.
///
/// The menu item `Check for Updates…` still works: on click Sparkle
/// attempts a fresh check, which (once the feed and key are set up in
/// Info.plist) will then prompt and install updates normally.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    let updater: SPUStandardUpdaterController

    private override init() {
        updater = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        do {
            try updater.updater.start()
        } catch {
            NSLog("Sparkle updater did not start: \(error.localizedDescription)")
            // Intentional: without a valid appcast URL and public key the
            // updater can't initialise. That's fine — the user hasn't
            // configured distribution yet, and we don't want an error
            // dialog on every launch.
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates(sender)
    }
}
