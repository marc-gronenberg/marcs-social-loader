import Foundation
import Observation

/// Metadata for a playlist that was expanded into the queue. Shared
/// by every `VideoItem` that came from the same source playlist so
/// the UI can render them as a collapsible group with a header,
/// a per-group quality picker, and a "remove all" action.
struct PlaylistGroup: Identifiable, Hashable {
    let id: UUID
    let title: String
    /// The original URL the user pasted (e.g. a
    /// `youtube.com/playlist?list=X` page). Used as a dedup key so
    /// re-pasting the same playlist doesn't create a second group.
    let sourceURL: String

    init(title: String, sourceURL: String) {
        self.id = UUID()
        self.title = title
        self.sourceURL = sourceURL
    }
}

/// One row in the download queue. Observable so SwiftUI views
/// automatically re-render on state changes.
@Observable
final class VideoItem: Identifiable, Hashable {
    let id = UUID()
    let url: String

    /// If this item was created by expanding a playlist, the id of
    /// the `PlaylistGroup` it belongs to. `nil` for standalone items.
    /// The `DownloadManager.sections` property uses this to render
    /// consecutive items with the same group as a single collapsible
    /// block in the UI.
    var groupId: UUID?

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

    /// Target progress 0.0 … 1.0 — written by the download parser, monotonic.
    /// The UI does not bind to this directly; it reads `displayedProgress`,
    /// which the smoother continuously interpolates toward this value so the
    /// bar moves evenly even when yt-dlp emits updates in bursts.
    var progress: Double = 0
    /// Smoothed value the progress bar actually renders. 0.0 … 1.0.
    var displayedProgress: Double = 0
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

    /// Pre-populates `info` with the data we already have from a
    /// `--flat-playlist` dump so the row can render a meaningful title
    /// (and, when available, a thumbnail) without waiting for a full
    /// per-video metadata fetch.
    ///
    /// `heights` is left empty — it can only come from a full
    /// `--dump-json` call. That means the quality picker only offers
    /// "Beste Qualität" and "Audio (MP3)" until the enrichment fetch
    /// lands. Selected quality is reset to "best" so the picker doesn't
    /// end up showing a saved default (e.g. "1080p") that isn't in its
    /// current option list.
    func applyPreliminary(
        title: String,
        thumbnail: URL?,
        duration: Int?,
        id: String?,
        webpageURL: URL?
    ) {
        self.info = Metadata.Info(
            id: id ?? "",
            title: title,
            duration: duration,
            thumbnail: thumbnail,
            uploader: nil,
            webpageURL: webpageURL,
            heights: []
        )
        self.selectedQuality = "best"
        self.state = .ready
    }
}
