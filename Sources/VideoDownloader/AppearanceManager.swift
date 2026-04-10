import AppKit
import SwiftUI

/// Brand red, sampled from the app icon (~#C7413F). Used for the in-window
/// progress bar and the dock-tile overlay so both match the icon.
enum BrandColor {
    static let red = NSColor(srgbRed: 199.0/255.0, green: 65.0/255.0, blue: 63.0/255.0, alpha: 1.0)
    static let redSwiftUI = Color(.sRGB, red: 199.0/255.0, green: 65.0/255.0, blue: 63.0/255.0, opacity: 1.0)
}

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
