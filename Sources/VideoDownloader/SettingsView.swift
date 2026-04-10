import SwiftUI

struct SettingsView: View {
    @Environment(Localization.self) private var l10n

    @State private var language: AppLanguage
    @State private var appearance: AppearanceMode

    init() {
        let cfg = AppConfig.load()
        // Use the in-memory language (already resolved via effectiveLanguage
        // in main.swift) so the picker shows the auto-detected value on
        // first launch instead of no selection.
        _language = State(initialValue: Localization.shared.language)
        _appearance = State(initialValue: cfg.appearance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Language
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.str(.language))
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
                .onChange(of: language) { _, new in
                    l10n.setLanguage(new)
                    var cfg = AppConfig.load()
                    cfg.language = new
                    cfg.save()
                }
                Text(l10n.str(.settingsLanguageHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Appearance
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.str(.appearance))
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: $appearance) {
                    Text(l10n.str(.appearanceSystem)).tag(AppearanceMode.system)
                    Text(l10n.str(.appearanceLight)).tag(AppearanceMode.light)
                    Text(l10n.str(.appearanceDark)).tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: appearance) { _, new in
                    AppearanceApplier.apply(new)
                    var cfg = AppConfig.load()
                    cfg.appearance = new
                    cfg.save()
                }
                Text(l10n.str(.settingsAppearanceHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // Version footer — reads live from the running bundle.
            HStack {
                Spacer()
                Text(versionString)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(width: 420, height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }
}
