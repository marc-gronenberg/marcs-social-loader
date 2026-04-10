import Foundation
import Observation

// MARK: - Languages

enum AppLanguage: String, CaseIterable, Codable {
    case german        = "de"
    case english       = "en"
    case italian       = "it"
    case maltese       = "mt"
    case swissGerman   = "gsw"
    case austrian      = "de-AT"
    case french        = "fr"
    case luxembourgish = "lb"
    case romansh       = "rm"

    var displayName: String {
        switch self {
        case .german:        return "Deutsch"
        case .english:       return "English"
        case .italian:       return "Italiano"
        case .maltese:       return "Malti"
        case .swissGerman:   return "Schwiizerdütsch"
        case .austrian:      return "Österreichisch"
        case .french:        return "Français"
        case .luxembourgish: return "Lëtzebuergesch"
        case .romansh:       return "Rumantsch"
        }
    }

    /// Picks a language from the user's macOS "Preferred Languages" list.
    /// Used on first launch, before the user has explicitly picked one in
    /// the Settings window.
    static func autoDetect() -> AppLanguage {
        for raw in Locale.preferredLanguages {
            let code = raw.lowercased()
            if code.hasPrefix("de-at") { return .austrian }
            if code.hasPrefix("de-ch") || code.hasPrefix("gsw") { return .swissGerman }
            if code.hasPrefix("de")    { return .german }
            if code.hasPrefix("en")    { return .english }
            if code.hasPrefix("it")    { return .italian }
            if code.hasPrefix("mt")    { return .maltese }
            if code.hasPrefix("fr")    { return .french }
            if code.hasPrefix("lb")    { return .luxembourgish }
            if code.hasPrefix("rm")    { return .romansh }
        }
        return .english
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("appLanguageChanged")
}

// MARK: - Observable localization store

@Observable
@MainActor
final class Localization {
    static let shared = Localization()

    var language: AppLanguage = .german

    private init() {}

    func str(_ key: L10n) -> String {
        return key.translations[language] ?? key.translations[.german]!
    }

    func str(_ key: L10n, _ args: CVarArg...) -> String {
        let template = key.translations[language] ?? key.translations[.german]!
        return String(format: template, arguments: args)
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        language = lang
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
}

// MARK: - String keys

enum L10n {
    case emptyHeading
    case emptyBody
    case pasteButton
    case saveLocation
    case changeButton
    case downloadButtonIdle
    case downloadButtonBusy
    case downloadButtonSingle
    case downloadButtonMany
    case pickerPrompt
    case pickerTitle
    case pickerMessage
    case loadingInfo
    case waiting
    case downloadStatus
    case extractingAudio
    case converting
    case postprocessing
    case doneMark
    case errorLoading
    case qualityBest
    case qualityAudioMP3
    case tooltipRename
    case tooltipCancelDownload
    case tooltipRemove
    case errorInvalidURL
    case errorDuplicate
    case settings
    case language
    case appearance
    case appearanceSystem
    case appearanceLight
    case appearanceDark
    case settingsLanguageHelp
    case settingsAppearanceHelp
    case menuAbout
    case menuHide
    case menuQuit
    case menuSettings
    case menuWindow
    case menuMinimize
    case menuClose
    case menuCheckForUpdates

    // Notifications
    case notificationDoneBody
    case notificationRevealAction

    var translations: [AppLanguage: String] {
        switch self {

        case .emptyHeading: return [
            .german:        "Video-URL aus der Zwischenablage einfügen",
            .english:       "Paste video URL from clipboard",
            .italian:       "Incolla l'URL del video dagli appunti",
            .maltese:       "Waħħal l-URL tal-vidjo mill-clipboard",
            .swissGerman:   "Video-URL us em Zwüschespycher iifüege",
            .austrian:      "Video-URL aus'm Zwischenspeicher einfügen",
            .french:        "Coller l'URL vidéo depuis le presse-papiers",
            .luxembourgish: "Video-URL aus der Zwëschenoflag aféieren",
            .romansh:       "Encollar l'URL video da la memoria intermedia"
        ]
        case .emptyBody: return [
            .german:        "Kopiere eine Video-URL von YouTube, Instagram,\nTikTok, X oder einer anderen Plattform und klicke\nhier – oder drücke ⌘V.",
            .english:       "Copy a video URL from YouTube, Instagram,\nTikTok, X or another platform and click here –\nor press ⌘V.",
            .italian:       "Copia l'URL di un video da YouTube, Instagram,\nTikTok, X o un'altra piattaforma e fai clic qui –\noppure premi ⌘V.",
            .maltese:       "Ikkopja URL ta' vidjo minn YouTube, Instagram,\nTikTok, X jew pjattaforma oħra u kklikkja hawn –\njew agħfas ⌘V.",
            .swissGerman:   "Kopier e Video-URL vo YouTube, Instagram,\nTikTok, X oder ere andere Plattform und klick\ndoo – oder drück ⌘V.",
            .austrian:      "Kopier' a Video-URL von YouTube, Instagram,\nTikTok, X oder einer anderen Plattform und klick\nda – oder drück' ⌘V.",
            .french:        "Copiez une URL vidéo depuis YouTube, Instagram,\nTikTok, X ou une autre plateforme et cliquez\nici – ou appuyez sur ⌘V.",
            .luxembourgish: "Kopéier eng Video-URL vu YouTube, Instagram,\nTikTok, X oder enger anerer Plattform a klick\nhei – oder dréck ⌘V.",
            .romansh:       "Copiai in URL video da YouTube, Instagram,\nTikTok, X u d'ina autra plattafurma e cliccai\nqua – u smaccai ⌘V."
        ]
        case .pasteButton: return [
            .german:        "URL aus Zwischenablage einfügen",
            .english:       "Paste URL from clipboard",
            .italian:       "Incolla URL dagli appunti",
            .maltese:       "Waħħal URL mill-clipboard",
            .swissGerman:   "URL us em Zwüschespycher iifüege",
            .austrian:      "URL aus'm Zwischenspeicher einfügen",
            .french:        "Coller l'URL depuis le presse-papiers",
            .luxembourgish: "URL aus der Zwëschenoflag aféieren",
            .romansh:       "Encollar URL da la memoria intermedia"
        ]
        case .saveLocation: return [
            .german:        "Speicherort:",
            .english:       "Save to:",
            .italian:       "Destinazione:",
            .maltese:       "Issejvja fi:",
            .swissGerman:   "Spycherort:",
            .austrian:      "Speicherort:",
            .french:        "Emplacement :",
            .luxembourgish: "Späicherplaz:",
            .romansh:       "Locaziun:"
        ]
        case .changeButton: return [
            .german:        "Ändern…",
            .english:       "Change…",
            .italian:       "Cambia…",
            .maltese:       "Biddel…",
            .swissGerman:   "Ändere…",
            .austrian:      "Ändern…",
            .french:        "Modifier…",
            .luxembourgish: "Änneren…",
            .romansh:       "Midar…"
        ]
        case .downloadButtonIdle: return [
            .german:        "Alle herunterladen",
            .english:       "Download all",
            .italian:       "Scarica tutti",
            .maltese:       "Niżżel kollox",
            .swissGerman:   "Alli abelade",
            .austrian:      "Olle owaloaden",
            .french:        "Tout télécharger",
            .luxembourgish: "All eroflueden",
            .romansh:       "Telechargiar tut"
        ]
        case .downloadButtonBusy: return [
            .german:        "Lade…",
            .english:       "Downloading…",
            .italian:       "Scaricando…",
            .maltese:       "Qed jitniżżel…",
            .swissGerman:   "Ladet…",
            .austrian:      "Ladt…",
            .french:        "Téléchargement…",
            .luxembourgish: "Luet…",
            .romansh:       "Telechargeond…"
        ]
        case .downloadButtonSingle: return [
            .german:        "%d Video herunterladen",
            .english:       "Download %d video",
            .italian:       "Scarica %d video",
            .maltese:       "Niżżel %d vidjo",
            .swissGerman:   "%d Video abelade",
            .austrian:      "%d Video owaloaden",
            .french:        "Télécharger %d vidéo",
            .luxembourgish: "%d Video eroflueden",
            .romansh:       "Telechargiar %d video"
        ]
        case .downloadButtonMany: return [
            .german:        "%d Videos herunterladen",
            .english:       "Download %d videos",
            .italian:       "Scarica %d video",
            .maltese:       "Niżżel %d vidjos",
            .swissGerman:   "%d Videos abelade",
            .austrian:      "%d Videos owaloaden",
            .french:        "Télécharger %d vidéos",
            .luxembourgish: "%d Videoen eroflueden",
            .romansh:       "Telechargiar %d videos"
        ]
        case .pickerPrompt: return [
            .german:        "Wählen",
            .english:       "Choose",
            .italian:       "Scegli",
            .maltese:       "Agħżel",
            .swissGerman:   "Uuswähle",
            .austrian:      "Auswählen",
            .french:        "Choisir",
            .luxembourgish: "Auswielen",
            .romansh:       "Tscherner"
        ]
        case .pickerTitle: return [
            .german:        "Speicherort wählen",
            .english:       "Choose save location",
            .italian:       "Scegli la destinazione",
            .maltese:       "Agħżel fejn tissejvja",
            .swissGerman:   "Spycherort uuswähle",
            .austrian:      "Speicherort auswählen",
            .french:        "Choisir l'emplacement",
            .luxembourgish: "Späicherplaz auswielen",
            .romansh:       "Tscherner la locaziun"
        ]
        case .pickerMessage: return [
            .german:        "Wo sollen die Videos gespeichert werden?",
            .english:       "Where should the videos be saved?",
            .italian:       "Dove salvare i video?",
            .maltese:       "Fejn għandhom jiġu ssejvjati l-vidjos?",
            .swissGerman:   "Wo söled d'Videos gspycheret wärde?",
            .austrian:      "Wo solln' de Videos gspeichert wer'n?",
            .french:        "Où les vidéos doivent-elles être enregistrées ?",
            .luxembourgish: "Wou solle d'Videoe gespäichert ginn?",
            .romansh:       "Nua duain ils videos vegnir memorisads?"
        ]
        case .loadingInfo: return [
            .german:        "Lade Infos…",
            .english:       "Loading info…",
            .italian:       "Caricamento info…",
            .maltese:       "Qed inġib l-info…",
            .swissGerman:   "Lad Infos…",
            .austrian:      "Lad' Infos…",
            .french:        "Chargement des infos…",
            .luxembourgish: "Lueden Infoen…",
            .romansh:       "Chargiond info…"
        ]
        case .waiting: return [
            .german:        "Warte…",
            .english:       "Waiting…",
            .italian:       "In attesa…",
            .maltese:       "Qed nistenna…",
            .swissGerman:   "Wart…",
            .austrian:      "Wart'…",
            .french:        "En attente…",
            .luxembourgish: "Waart…",
            .romansh:       "Spetgond…"
        ]
        case .downloadStatus: return [
            .german:        "Download · %@ · ETA %@",
            .english:       "Downloading · %@ · ETA %@",
            .italian:       "Download · %@ · ETA %@",
            .maltese:       "Download · %@ · ETA %@",
            .swissGerman:   "Download · %@ · ETA %@",
            .austrian:      "Download · %@ · ETA %@",
            .french:        "Téléchargement · %@ · ETA %@",
            .luxembourgish: "Download · %@ · ETA %@",
            .romansh:       "Download · %@ · ETA %@"
        ]
        case .extractingAudio: return [
            .german:        "Extrahiere Audio…",
            .english:       "Extracting audio…",
            .italian:       "Estrazione audio…",
            .maltese:       "Qed nestratti l-awdjo…",
            .swissGerman:   "Audio useziäh…",
            .austrian:      "Audio aussalesen…",
            .french:        "Extraction audio…",
            .luxembourgish: "Audio erausléisen…",
            .romansh:       "Extrahend l'audio…"
        ]
        case .converting: return [
            .german:        "Konvertiere…",
            .english:       "Converting…",
            .italian:       "Conversione…",
            .maltese:       "Qed nikkonverti…",
            .swissGerman:   "Konvertiere…",
            .austrian:      "Konvertier'…",
            .french:        "Conversion…",
            .luxembourgish: "Konvertéieren…",
            .romansh:       "Convertend…"
        ]
        case .postprocessing: return [
            .german:        "Nachbearbeitung…",
            .english:       "Processing…",
            .italian:       "Elaborazione…",
            .maltese:       "Qed jiġi pproċessat…",
            .swissGerman:   "Nachbearbeitig…",
            .austrian:      "Nachbearbeitung…",
            .french:        "Traitement…",
            .luxembourgish: "Nobeaarbechtung…",
            .romansh:       "Posttractament…"
        ]
        case .doneMark: return [
            .german:        "✓ Fertig",
            .english:       "✓ Done",
            .italian:       "✓ Fatto",
            .maltese:       "✓ Lest",
            .swissGerman:   "✓ Fertig",
            .austrian:      "✓ Fertig",
            .french:        "✓ Terminé",
            .luxembourgish: "✓ Fäerdeg",
            .romansh:       "✓ Finì"
        ]
        case .errorLoading: return [
            .german:        "✗ Fehler beim Laden",
            .english:       "✗ Loading failed",
            .italian:       "✗ Caricamento fallito",
            .maltese:       "✗ Falla t-tagħbija",
            .swissGerman:   "✗ Fähler bim Lade",
            .austrian:      "✗ Fehler beim Laden",
            .french:        "✗ Échec du chargement",
            .luxembourgish: "✗ Feeler beim Lueden",
            .romansh:       "✗ Chargiada faglida"
        ]
        case .qualityBest: return [
            .german:        "Beste Qualität",
            .english:       "Best quality",
            .italian:       "Migliore qualità",
            .maltese:       "L-aħjar kwalità",
            .swissGerman:   "Beschti Qualität",
            .austrian:      "Beste Qualität",
            .french:        "Meilleure qualité",
            .luxembourgish: "Bescht Qualitéit",
            .romansh:       "Bunissima qualitad"
        ]
        case .qualityAudioMP3: return [
            .german:        "Audio (MP3)",
            .english:       "Audio (MP3)",
            .italian:       "Audio (MP3)",
            .maltese:       "Awdjo (MP3)",
            .swissGerman:   "Audio (MP3)",
            .austrian:      "Audio (MP3)",
            .french:        "Audio (MP3)",
            .luxembourgish: "Audio (MP3)",
            .romansh:       "Audio (MP3)"
        ]
        case .tooltipRename: return [
            .german:        "Doppelklick zum Umbenennen",
            .english:       "Double-click to rename",
            .italian:       "Doppio clic per rinominare",
            .maltese:       "Ikklikkja darbtejn biex tibdel l-isem",
            .swissGerman:   "Doppelklick zum Umtaufe",
            .austrian:      "Doppelklick zum Umbenennen",
            .french:        "Double-cliquer pour renommer",
            .luxembourgish: "Duebelklick fir ëmbenennen",
            .romansh:       "Clic dubel per renumnar"
        ]
        case .tooltipCancelDownload: return [
            .german:        "Download abbrechen",
            .english:       "Cancel download",
            .italian:       "Annulla download",
            .maltese:       "Ikkanċella d-download",
            .swissGerman:   "Download abbräche",
            .austrian:      "Download obrechen",
            .french:        "Annuler le téléchargement",
            .luxembourgish: "Download ofbriechen",
            .romansh:       "Annullar il telechargiar"
        ]
        case .tooltipRemove: return [
            .german:        "Entfernen",
            .english:       "Remove",
            .italian:       "Rimuovi",
            .maltese:       "Neħħi",
            .swissGerman:   "Entfärne",
            .austrian:      "Entfernen",
            .french:        "Supprimer",
            .luxembourgish: "Ewechhuelen",
            .romansh:       "Allontanar"
        ]
        case .errorInvalidURL: return [
            .german:        "Bitte eine vollständige URL eingeben.",
            .english:       "Please enter a complete URL.",
            .italian:       "Inserisci un URL completo.",
            .maltese:       "Jekk jogħġbok daħħal URL sħiħ.",
            .swissGerman:   "Bitte gib e vollständigi URL ii.",
            .austrian:      "Bitte gib a vollständige URL ein.",
            .french:        "Veuillez saisir une URL complète.",
            .luxembourgish: "W.e.g. eng komplett URL aginn.",
            .romansh:       "Endatai in URL cumplet per plaschair."
        ]
        case .errorDuplicate: return [
            .german:        "Diese URL ist schon in der Liste.",
            .english:       "This URL is already in the list.",
            .italian:       "Questo URL è già nella lista.",
            .maltese:       "Dan l-URL diġà jinsab fil-lista.",
            .swissGerman:   "Die URL isch scho i de Lischte.",
            .austrian:      "De URL is scho in der Liste.",
            .french:        "Cette URL est déjà dans la liste.",
            .luxembourgish: "Dës URL ass schonn op der Lëscht.",
            .romansh:       "Quest URL è gia sin la glista."
        ]
        case .settings: return [
            .german:        "Einstellungen",
            .english:       "Settings",
            .italian:       "Impostazioni",
            .maltese:       "Settings",
            .swissGerman:   "Iistellige",
            .austrian:      "Einstellungen",
            .french:        "Réglages",
            .luxembourgish: "Astellungen",
            .romansh:       "Parameters"
        ]
        case .language: return [
            .german:        "Sprache",
            .english:       "Language",
            .italian:       "Lingua",
            .maltese:       "Lingwa",
            .swissGerman:   "Sproch",
            .austrian:      "Sprache",
            .french:        "Langue",
            .luxembourgish: "Sprooch",
            .romansh:       "Lingua"
        ]
        case .appearance: return [
            .german:        "Erscheinungsbild",
            .english:       "Appearance",
            .italian:       "Aspetto",
            .maltese:       "Dehra",
            .swissGerman:   "Erschiinigsbild",
            .austrian:      "Erscheinungsbild",
            .french:        "Apparence",
            .luxembourgish: "Ausgesinn",
            .romansh:       "Apparientscha"
        ]
        case .appearanceSystem: return [
            .german:        "System",
            .english:       "System",
            .italian:       "Sistema",
            .maltese:       "Sistema",
            .swissGerman:   "System",
            .austrian:      "System",
            .french:        "Système",
            .luxembourgish: "System",
            .romansh:       "Sistem"
        ]
        case .appearanceLight: return [
            .german:        "Hell",
            .english:       "Light",
            .italian:       "Chiaro",
            .maltese:       "Ċar",
            .swissGerman:   "Häll",
            .austrian:      "Hell",
            .french:        "Clair",
            .luxembourgish: "Hell",
            .romansh:       "Cler"
        ]
        case .appearanceDark: return [
            .german:        "Dunkel",
            .english:       "Dark",
            .italian:       "Scuro",
            .maltese:       "Skur",
            .swissGerman:   "Dunkel",
            .austrian:      "Dunkel",
            .french:        "Sombre",
            .luxembourgish: "Donkel",
            .romansh:       "Stgir"
        ]
        case .settingsLanguageHelp: return [
            .german:        "Sprache der Benutzeroberfläche.",
            .english:       "User interface language.",
            .italian:       "Lingua dell'interfaccia utente.",
            .maltese:       "Il-lingwa tal-interface.",
            .swissGerman:   "Sproch vom Programm.",
            .austrian:      "Sprache vom Programm.",
            .french:        "Langue de l'interface utilisateur.",
            .luxembourgish: "D'Sprooch vun der Uewerfläch.",
            .romansh:       "Lingua da l'interfatscha d'utilisader."
        ]
        case .settingsAppearanceHelp: return [
            .german:        "Hell, dunkel oder dem System folgen.",
            .english:       "Light, dark, or follow the system.",
            .italian:       "Chiaro, scuro o segui il sistema.",
            .maltese:       "Ċar, skur jew segwi s-sistema.",
            .swissGerman:   "Häll, dunkel oder em System noogoo.",
            .austrian:      "Hell, dunkel oder dem System folgen.",
            .french:        "Clair, sombre ou suivre le système.",
            .luxembourgish: "Hell, donkel oder dem System suivéieren.",
            .romansh:       "Cler, stgir u suandar il sistem."
        ]
        case .menuAbout: return [
            .german:        "Über %@",
            .english:       "About %@",
            .italian:       "Informazioni su %@",
            .maltese:       "Dwar %@",
            .swissGerman:   "Über %@",
            .austrian:      "Über %@",
            .french:        "À propos de %@",
            .luxembourgish: "Iwwer %@",
            .romansh:       "Davart %@"
        ]
        case .menuHide: return [
            .german:        "%@ ausblenden",
            .english:       "Hide %@",
            .italian:       "Nascondi %@",
            .maltese:       "Aħbi %@",
            .swissGerman:   "%@ uusblände",
            .austrian:      "%@ ausblenden",
            .french:        "Masquer %@",
            .luxembourgish: "%@ verstoppen",
            .romansh:       "Zuppentar %@"
        ]
        case .menuQuit: return [
            .german:        "%@ beenden",
            .english:       "Quit %@",
            .italian:       "Esci da %@",
            .maltese:       "Oħroġ minn %@",
            .swissGerman:   "%@ beände",
            .austrian:      "%@ beenden",
            .french:        "Quitter %@",
            .luxembourgish: "%@ verloossen",
            .romansh:       "Terminar %@"
        ]
        case .menuSettings: return [
            .german:        "Einstellungen…",
            .english:       "Settings…",
            .italian:       "Impostazioni…",
            .maltese:       "Settings…",
            .swissGerman:   "Iistellige…",
            .austrian:      "Einstellungen…",
            .french:        "Réglages…",
            .luxembourgish: "Astellungen…",
            .romansh:       "Parameters…"
        ]
        case .menuWindow: return [
            .german:        "Fenster",
            .english:       "Window",
            .italian:       "Finestra",
            .maltese:       "Tieqa",
            .swissGerman:   "Feischter",
            .austrian:      "Fenster",
            .french:        "Fenêtre",
            .luxembourgish: "Fënster",
            .romansh:       "Fanestra"
        ]
        case .menuMinimize: return [
            .german:        "Minimieren",
            .english:       "Minimize",
            .italian:       "Riduci a icona",
            .maltese:       "Immimizza",
            .swissGerman:   "Chliner mache",
            .austrian:      "Minimieren",
            .french:        "Réduire",
            .luxembourgish: "Miniméieren",
            .romansh:       "Minimisar"
        ]
        case .menuClose: return [
            .german:        "Schließen",
            .english:       "Close",
            .italian:       "Chiudi",
            .maltese:       "Agħlaq",
            .swissGerman:   "Zuemache",
            .austrian:      "Zumachen",
            .french:        "Fermer",
            .luxembourgish: "Zoumaachen",
            .romansh:       "Serrar"
        ]
        case .menuCheckForUpdates: return [
            .german:        "Nach Updates suchen…",
            .english:       "Check for Updates…",
            .italian:       "Verifica aggiornamenti…",
            .maltese:       "Iċċekkja għal aġġornamenti…",
            .swissGerman:   "Nach Updates sueche…",
            .austrian:      "Nach Updates schauen…",
            .french:        "Rechercher les mises à jour…",
            .luxembourgish: "No Updates kucken…",
            .romansh:       "Tschertgar actualisaziuns…"
        ]
        case .notificationDoneBody: return [
            .german:        "Download abgeschlossen",
            .english:       "Download complete",
            .italian:       "Download completato",
            .maltese:       "Download lest",
            .swissGerman:   "Download fertig",
            .austrian:      "Download fertig",
            .french:        "Téléchargement terminé",
            .luxembourgish: "Download ofgeschloss",
            .romansh:       "Telechargiar terminà"
        ]
        case .notificationRevealAction: return [
            .german:        "Im Finder anzeigen",
            .english:       "Show in Finder",
            .italian:       "Mostra nel Finder",
            .maltese:       "Uri fil-Finder",
            .swissGerman:   "Im Finder zeige",
            .austrian:      "Im Finder anzeigen",
            .french:        "Afficher dans le Finder",
            .luxembourgish: "Am Finder weisen",
            .romansh:       "Mussar en il Finder"
        ]
        }
    }
}
