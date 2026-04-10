import SwiftUI
import AppKit

// Manual NSApplication bootstrap so the executable works both via
// `swift run` (for development) and from a packaged .app bundle.

@MainActor
final class WindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

// MARK: - Settings window

@MainActor
final class SettingsWindowHolder {
    static let shared = SettingsWindowHolder()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView:
            SettingsView().environment(Localization.shared)
        )
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = Localization.shared.str(.settings)
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshTitle() {
        window?.title = Localization.shared.str(.settings)
    }
}

@objc @MainActor
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func openSettings() {
        SettingsWindowHolder.shared.show()
    }
}

// MARK: - Main menu

@MainActor
func buildMainMenu() -> NSMenu {
    let l10n = Localization.shared
    let appName = "Marc's Social Loader"

    let mainMenu = NSMenu()

    // App menu
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: String(format: l10n.str(.menuAbout), appName),
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    let settingsItem = appMenu.addItem(
        withTitle: l10n.str(.menuSettings),
        action: #selector(MenuActionTarget.openSettings),
        keyEquivalent: ","
    )
    settingsItem.target = MenuActionTarget.shared
    appMenu.addItem(NSMenuItem.separator())
    let updateItem = appMenu.addItem(
        withTitle: l10n.str(.menuCheckForUpdates),
        action: #selector(UpdateController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    updateItem.target = UpdateController.shared
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
        withTitle: String(format: l10n.str(.menuHide), appName),
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
        withTitle: String(format: l10n.str(.menuQuit), appName),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // Window menu
    let windowMenuItem = NSMenuItem()
    let windowMenu = NSMenu(title: l10n.str(.menuWindow))
    windowMenu.addItem(
        withTitle: l10n.str(.menuMinimize),
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
    )
    windowMenu.addItem(
        withTitle: l10n.str(.menuClose),
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)

    return mainMenu
}

@MainActor
final class MenuRebuildObserver: NSObject {
    static let shared = MenuRebuildObserver()
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rebuild),
            name: .appLanguageChanged,
            object: nil
        )
    }
    @objc func rebuild() {
        NSApp.mainMenu = buildMainMenu()
        SettingsWindowHolder.shared.refreshTitle()
    }
}

// MARK: - App bootstrap

@MainActor
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    // Load persisted settings and apply them before building the UI so
    // everything comes up in the right language / appearance.
    // On first launch `config.language` is nil → we fall back to the
    // macOS system language via `effectiveLanguage`. Once the user picks
    // a language in the Settings window that choice is written to disk
    // and used on every subsequent launch.
    let config = AppConfig.load()
    Localization.shared.language = config.effectiveLanguage
    AppearanceApplier.apply(config.appearance)

    app.mainMenu = buildMainMenu()
    _ = MenuRebuildObserver.shared

    let manager = DownloadManager(config: config)

    let hostingView = NSHostingView(rootView:
        ContentView()
            .environment(manager)
            .environment(Localization.shared)
    )

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = "Marc's Social Loader"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.contentView = hostingView
    window.center()
    window.setFrameAutosaveName("VideoDownloaderMainWindow")

    let delegate = WindowDelegate()
    window.delegate = delegate
    objc_setAssociatedObject(window, "delegateRetain", delegate, .OBJC_ASSOCIATION_RETAIN)

    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    // Start the Dock-icon appearance observer.
    _ = IconController.shared

    // Install the custom Dock-tile content view. It draws the app icon
    // plus a slim progress bar while downloads are running.
    app.dockTile.contentView = DockProgressView.shared
    app.dockTile.display()

    // Spin up Sparkle so the scheduled update check runs and the menu
    // item has a live target.
    _ = UpdateController.shared

    app.run()
}

MainActor.assumeIsolated { runApp() }
