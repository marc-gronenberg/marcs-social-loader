import AppKit

enum AppearanceMode: String, CaseIterable, Codable {
    case system
    case light
    case dark
}

@MainActor
enum AppearanceApplier {
    /// Applies the requested appearance to the running app. Setting
    /// `NSApp.appearance = nil` makes the app follow the system setting.
    static func apply(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
