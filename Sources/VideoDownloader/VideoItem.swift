import Foundation
import Observation

/// One row in the download queue. Observable so SwiftUI views
/// automatically re-render on state changes.
@Observable
final class VideoItem: Identifiable, Hashable {
    let id = UUID()
    let url: String

    enum State: Equatable {
        case loading
        case ready
        case downloading
        case postprocessing
        case done
        case error(String)
    }

    var state: State = .loading
    var info: Metadata.Info?
    var selectedQuality: String = "best"
    /// Overrides the fetched title for display and output filename when set.
    var customTitle: String?

    /// 0.0 … 1.0
    var progress: Double = 0
    /// Free-form label shown above the progress bar
    var statusLine: String = ""
    /// Final file on disk once the download finishes
    var finalFile: URL?

    init(url: String, defaultQuality: String) {
        self.url = url
        self.selectedQuality = defaultQuality
    }

    // Hashable / Equatable by identity
    static func == (lhs: VideoItem, rhs: VideoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Display helpers

    var durationText: String {
        guard let d = info?.duration, d > 0 else { return "--:--" }
        let h = d / 3600, m = (d % 3600) / 60, s = d % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return info?.title ?? url
    }

    /// List of quality keys to show in the picker for this specific video.
    /// "best", then each height, then "audio_mp3".
    var qualityOptions: [(key: String, label: String)] {
        var opts: [(String, String)] = [("best", "Beste Qualität")]
        for h in info?.heights ?? [] {
            opts.append(("\(h)p", "\(h)p"))
        }
        opts.append(("audio_mp3", "Audio (MP3)"))
        return opts
    }
}
