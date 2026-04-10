import AppKit

/// Swaps `NSApp.applicationIconImage` at runtime whenever the system
/// appearance changes, so the Dock icon reflects light/dark mode.
///
/// macOS does not do this automatically — the .icns inside the bundle is
/// a single fixed image. The runtime override is visible immediately in
/// the Dock as long as the app is running. When the app is quit, Finder
/// / Spotlight / Launchpad fall back to the baseline .icns.
@MainActor
final class IconController: NSObject {

    static let shared = IconController()

    private var lightIcon: NSImage?
    private var darkIcon: NSImage?
    private var observation: NSKeyValueObservation?

    private override init() {
        super.init()
        loadIcons()
        // Apply the current appearance once, then watch for changes.
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // The observer fires on the thread that triggered the change
            // (usually main), but marshal explicitly to be safe.
            Task { @MainActor in self?.apply() }
        }
    }

    private func loadIcons() {
        if let url = Bundle.main.url(forResource: "AppIcon-Light", withExtension: "png") {
            lightIcon = NSImage(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: "AppIcon-Dark", withExtension: "png") {
            darkIcon = NSImage(contentsOf: url)
        }
    }

    private func apply() {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        let isDark = (match == .darkAqua)

        if isDark, let dark = darkIcon {
            NSApp.applicationIconImage = dark
        } else if let light = lightIcon {
            NSApp.applicationIconImage = light
        }
        // If neither icon is available the system falls back to the .icns
        // shipped inside the bundle — nothing to do.

        // Tell the custom Dock tile view to redraw so it picks up the
        // newly-assigned applicationIconImage.
        DockProgressView.shared.refresh()
    }
}
