import Foundation

/// Tiny JSON-backed config for the app. Remembers the last output
/// directory, the last-picked quality, the preferred UI language, and
/// the preferred appearance mode.
struct AppConfig: Codable {
    var outputDir: String
    var defaultQuality: String
    /// `nil` means "auto-detect from the system language". Once the user
    /// explicitly picks a language in the Settings window, a concrete
    /// value is stored here and stays on disk across launches.
    var language: AppLanguage?
    var appearance: AppearanceMode

    /// Resolves `language` into a concrete value, falling back to the
    /// system auto-detection when nothing has been saved yet.
    var effectiveLanguage: AppLanguage {
        language ?? AppLanguage.autoDetect()
    }

    static var defaultValue: AppConfig {
        AppConfig(
            outputDir: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
            defaultQuality: "best",
            language: nil,       // auto-detect until the user picks one
            appearance: .system
        )
    }

    static var configURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VideoDownloader", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    // Decoding is tolerant of older config files that don't have the new
    // fields yet — missing keys fall back to the defaults.
    private enum CodingKeys: String, CodingKey {
        case outputDir, defaultQuality, language, appearance
    }

    init(outputDir: String, defaultQuality: String, language: AppLanguage?, appearance: AppearanceMode) {
        self.outputDir = outputDir
        self.defaultQuality = defaultQuality
        self.language = language
        self.appearance = appearance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppConfig.defaultValue
        self.outputDir = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? fallback.outputDir
        self.defaultQuality = try c.decodeIfPresent(String.self, forKey: .defaultQuality) ?? fallback.defaultQuality
        self.language = try c.decodeIfPresent(AppLanguage.self, forKey: .language)
        self.appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? fallback.appearance
    }

    static func load() -> AppConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .defaultValue
        }
        // Sanity: if the saved directory no longer exists, reset it.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cfg.outputDir, isDirectory: &isDir), isDir.boolValue {
            return cfg
        }
        return AppConfig(
            outputDir: AppConfig.defaultValue.outputDir,
            defaultQuality: cfg.defaultQuality,
            language: cfg.language,
            appearance: cfg.appearance
        )
    }

    func save() {
        let url = Self.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // non-fatal: a missing config will just fall back to defaults
        }
    }
}
