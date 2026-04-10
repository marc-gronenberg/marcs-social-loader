import Foundation
import Observation

/// Orchestrates yt-dlp downloads: builds the format spec, spawns the process,
/// parses its progress output, and updates per-item state on the main actor.
/// A section of the rendered queue — either a standalone video or a
/// playlist group with its own header and collapsible item list.
/// Computed from `DownloadManager.items` on each read.
enum QueueSection: Identifiable {
    case standalone(VideoItem)
    case group(PlaylistGroup, [VideoItem])

    var id: UUID {
        switch self {
        case .standalone(let item): return item.id
        case .group(let group, _):  return group.id
        }
    }
}

@MainActor
@Observable
final class DownloadManager {

    var items: [VideoItem] = []
    /// Metadata for every active playlist group, keyed by group id.
    /// Lives alongside `items`; removing the last item of a group
    /// also evicts its entry here so empty headers never hang
    /// around in the UI.
    var groups: [UUID: PlaylistGroup] = [:]
    var outputDir: String
    var statusLine: String = ""
    var isBatchRunning: Bool = false

    /// UI-facing view of the queue: walks `items` in order and
    /// coalesces consecutive items that share a `groupId` into a
    /// single `.group` section. Standalone items become `.standalone`
    /// sections. Since playlist expansion always appends its items
    /// contiguously, every group in the items array is naturally
    /// contiguous here too.
    var sections: [QueueSection] {
        var result: [QueueSection] = []
        var currentGroupId: UUID?
        var currentGroupItems: [VideoItem] = []

        func flushCurrentGroup() {
            guard let gid = currentGroupId, let group = groups[gid] else {
                currentGroupId = nil
                currentGroupItems = []
                return
            }
            result.append(.group(group, currentGroupItems))
            currentGroupId = nil
            currentGroupItems = []
        }

        for item in items {
            if let gid = item.groupId {
                if currentGroupId == gid {
                    currentGroupItems.append(item)
                } else {
                    flushCurrentGroup()
                    currentGroupId = gid
                    currentGroupItems = [item]
                }
            } else {
                flushCurrentGroup()
                result.append(.standalone(item))
            }
        }
        flushCurrentGroup()

        return result
    }

    /// Last-picked quality, applied as the default for newly added items.
    var defaultQuality: String

    private let maxParallel = 3

    /// Fraction of the bar reserved for postprocessing (merge / remux /
    /// audio extraction). Real download progress is squeezed into 0…(1-r),
    /// then postprocessing creeps the bar from there toward 1.0.
    private static let postprocessReserve: Double = 0.05
    private static let downloadCeiling: Double = 1.0 - postprocessReserve  // 0.95
    /// How fast displayedProgress catches up to progress, in units per
    /// second. ~2.5/s = a full-bar jump closes in ~0.4 s, which feels
    /// instant but still smooth.
    private static let catchUpVelocity: Double = 2.5
    /// Slower velocity used during postprocessing, where the target is the
    /// fixed downloadCeiling+ε and we want a calm visible creep.
    private static let postprocessVelocity: Double = 0.15

    /// Running yt-dlp processes keyed by item ID. Used to cancel a specific
    /// item's download when the user clicks X.
    private var activeProcesses: [UUID: Process] = [:]

    /// In-flight playlist prefetches keyed by URL. Populated by
    /// `prefetchURL(_:)` / `prefetchPlaylist(url:)` the moment a URL
    /// is detected in the system clipboard or the ambiguity dialog
    /// opens; consumed by `add(url:mode:.playlist)`. Each task collects
    /// every entry `streamPlaylistEntries` yields and returns them as
    /// an array once yt-dlp exits — awaiting it either returns instantly
    /// (the user took long enough to decide) or waits out the remaining
    /// yt-dlp time (still faster than starting a fresh process).
    private var playlistPrefetches: [String: Task<[Metadata.PlaylistEntry], Error>] = [:]

    /// In-flight single-video metadata prefetches keyed by URL. Same
    /// idea as `playlistPrefetches` but for regular video URLs — the
    /// moment clipboard detection sees a supported non-playlist URL,
    /// we kick off `Metadata.fetch` in the background so the title,
    /// thumbnail and height list are ready by the time the user
    /// actually clicks paste.
    private var singlePrefetches: [String: Task<Metadata.Info, Error>] = [:]

    /// 30 fps RunLoop timer that interpolates each active item's
    /// `displayedProgress` toward its `progress` target. Started lazily when
    /// the first download begins, stopped when no items are active anymore.
    private var smootherTimer: Timer?
    private static let smootherInterval: TimeInterval = 1.0 / 30.0

    init(config: AppConfig) {
        self.outputDir = config.outputDir
        self.defaultQuality = config.defaultQuality
    }

    // MARK: - Queue management

    /// How the queue should interpret an incoming URL.
    /// - `auto`: use the built-in heuristic (pure playlist URLs expand,
    ///   everything else is treated as a single video).
    /// - `videoOnly`: force single-video behavior, even if the URL
    ///   contains a `list=` playlist context.
    /// - `playlist`: force expansion, even if the URL looks like a
    ///   single-video watch URL.
    ///
    /// Used by the "Video or playlist?" confirmation dialog in the UI:
    /// when the user pastes a `watch?v=X&list=Y` URL, the UI asks which
    /// one they meant and then calls `add(url:mode:)` with the
    /// corresponding override.
    enum AddMode {
        case auto
        case videoOnly
        case playlist
    }

    /// Kicks off a background metadata fetch for `url` — picks the
    /// single-video or playlist path based on the URL heuristic.
    /// Called from the UI when a new URL is detected in the system
    /// clipboard (on app activation) so yt-dlp can do its work while
    /// the user is still reaching for the paste button. A subsequent
    /// `add(url:)` reuses the result instead of spawning a fresh
    /// yt-dlp.
    ///
    /// Idempotent: repeated calls with the same URL return without
    /// starting a second task. Skips URLs that look ambiguous
    /// (`watch?v=X&list=Y`) — those are handled by the explicit
    /// `prefetchPlaylist(url:)` path once the confirmation dialog
    /// decides which mode the user wants.
    func prefetchURL(_ url: String) {
        // Skip ambiguous URLs — the dialog will explicitly trigger
        // a playlist prefetch if the user picks "Ganze Playlist".
        // Prefetching as single video here would be wasted if they
        // pick "Ganze Playlist" instead, and vice versa.
        if Self.urlIsAmbiguousPlaylist(url) { return }

        if Self.urlLooksLikePlaylist(url) {
            prefetchPlaylist(url: url)
        } else {
            prefetchSingleVideo(url: url)
        }
    }

    /// Kicks off a background playlist enumeration. Used by both the
    /// ambiguity dialog (via `prefetchURL` → this) and the direct
    /// playlist-URL path from the clipboard.
    ///
    /// Idempotent: repeated calls with the same URL return without
    /// starting a second task. Safe to call on the main actor.
    func prefetchPlaylist(url: String) {
        guard playlistPrefetches[url] == nil else { return }
        playlistPrefetches[url] = Task.detached(priority: .userInitiated) {
            var collected: [Metadata.PlaylistEntry] = []
            for try await entry in Metadata.streamPlaylistEntries(url: url) {
                try Task.checkCancellation()
                collected.append(entry)
            }
            return collected
        }
    }

    /// Kicks off a background single-video metadata fetch. Used by
    /// the clipboard prefetch path so the title/thumbnail/heights for
    /// a standalone video URL are ready by the time the user pastes.
    private func prefetchSingleVideo(url: String) {
        guard singlePrefetches[url] == nil else { return }
        singlePrefetches[url] = Task.detached(priority: .userInitiated) {
            try await Metadata.fetch(url: url)
        }
    }

    /// Cancels a previously started prefetch (single or playlist).
    /// Called when the clipboard URL changes (stale cache) or the
    /// ambiguity dialog is dismissed without confirming.
    func cancelPrefetch(url: String) {
        playlistPrefetches.removeValue(forKey: url)?.cancel()
        singlePrefetches.removeValue(forKey: url)?.cancel()
    }

    func add(url: String, mode: AddMode = .auto) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            statusLine = "Bitte eine vollständige URL eingeben."
            return
        }

        // If the caller explicitly wants "just the video", strip any
        // playlist context parameters so yt-dlp can't get ideas later.
        // Also simplifies the duplicate check.
        let effectiveURL = (mode == .videoOnly)
            ? Self.stripPlaylistParams(from: trimmed)
            : trimmed

        if items.contains(where: { $0.url == effectiveURL }) {
            statusLine = "Diese URL ist schon in der Liste."
            return
        }

        // Decide whether to expand: explicit override wins, otherwise
        // fall back to the URL-shape heuristic.
        let shouldExpand: Bool
        switch mode {
        case .playlist:  shouldExpand = true
        case .videoOnly: shouldExpand = false
        case .auto:      shouldExpand = Self.urlLooksLikePlaylist(effectiveURL)
        }

        if !shouldExpand {
            // Single-video fast path.
            let item = VideoItem(url: effectiveURL, defaultQuality: defaultQuality)
            items.append(item)
            statusLine = "Bereit."

            // Fast path: the clipboard detector may already have
            // prefetched this URL's metadata in the background.
            // Consume the cached task instead of spawning a new one.
            if let cached = singlePrefetches.removeValue(forKey: effectiveURL) {
                Task { await self.consumeCachedSingle(task: cached, for: item) }
            } else {
                Task { await self.fetchInfo(for: item) }
            }
            return
        }

        // Playlist path: show a placeholder item while we ask yt-dlp to
        // enumerate the entries. Once they come back, we swap the
        // placeholder for one VideoItem per entry.
        let placeholder = VideoItem(url: effectiveURL, defaultQuality: defaultQuality)
        placeholder.state = .loading
        placeholder.statusLine = "Playlist wird geladen…"
        items.append(placeholder)
        statusLine = "Playlist wird geladen…"

        // Fast path: a prefetch for this exact URL is already running
        // (or finished) — await that instead of spawning a fresh
        // stream. This is the big win for the ambiguity dialog case:
        // by the time the user clicks "Ganze Playlist", yt-dlp has
        // usually finished in the background during the dialog.
        if let prefetch = playlistPrefetches.removeValue(forKey: effectiveURL) {
            Task { await self.consumePrefetchedPlaylist(prefetch: prefetch, url: effectiveURL, placeholder: placeholder) }
            return
        }

        Task { await self.expandPlaylist(url: effectiveURL, placeholder: placeholder) }
    }

    /// Awaits a previously-started playlist prefetch and populates the
    /// queue with its entries. Falls back to a fresh `expandPlaylist`
    /// call on any failure so the user never gets stuck with only a
    /// stale placeholder.
    private func consumePrefetchedPlaylist(
        prefetch: Task<[Metadata.PlaylistEntry], Error>,
        url: String,
        placeholder: VideoItem
    ) async {
        let entries: [Metadata.PlaylistEntry]
        do {
            entries = try await prefetch.value
        } catch {
            // Prefetch blew up — fall back to the normal streaming
            // expansion so the user still gets results.
            await expandPlaylist(url: url, placeholder: placeholder)
            return
        }

        // Make sure the placeholder is still in the list — the user
        // could have removed it between the click and now.
        guard items.contains(where: { $0.id == placeholder.id }) else { return }

        items.removeAll { $0.id == placeholder.id }

        // Register a playlist group using the title from the first
        // entry (yt-dlp propagates it into every flat-playlist entry).
        let playlistTitle = entries.first?.playlistTitle
            ?? Self.fallbackPlaylistTitle(for: url)
        let group = PlaylistGroup(title: playlistTitle, sourceURL: url)
        groups[group.id] = group

        var addedItems: [VideoItem] = []
        for entry in entries {
            if items.contains(where: { $0.url == entry.url }) { continue }
            let item = VideoItem(url: entry.url, defaultQuality: defaultQuality)
            item.groupId = group.id
            item.applyPreliminary(
                title: entry.title ?? "(unbenannt)",
                thumbnail: entry.thumbnail,
                duration: entry.duration,
                id: entry.id,
                webpageURL: URL(string: entry.url)
            )
            items.append(item)
            addedItems.append(item)
        }

        if addedItems.isEmpty {
            groups.removeValue(forKey: group.id)
            statusLine = "Playlist ist leer."
            return
        }
        statusLine = addedItems.count == 1
            ? "1 Video aus Playlist hinzugefügt."
            : "\(addedItems.count) Videos aus Playlist hinzugefügt."

        Task { await self.enrichMetadata(for: addedItems) }
    }

    /// Strips YouTube's playlist-context query params (`list`, `index`,
    /// `start_radio`, `pp`) from a URL so it refers to the single video
    /// only. Falls back to the original string if parsing fails.
    nonisolated static func stripPlaylistParams(from url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        let drop: Set<String> = ["list", "index", "start_radio", "pp"]
        comps.queryItems = comps.queryItems?.filter { !drop.contains($0.name) }
        if comps.queryItems?.isEmpty == true {
            comps.queryItems = nil
        }
        return comps.url?.absoluteString ?? url
    }

    /// True if a URL carries both a watch target and a playlist context,
    /// i.e. the user could reasonably have meant either "this video" or
    /// "the whole playlist". The caller shows a dialog and then re-calls
    /// `add(url:mode:)` with the chosen override.
    nonisolated static func urlIsAmbiguousPlaylist(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard lower.contains("/watch?") || lower.contains("/shorts/") else {
            return false
        }
        // Both must be present — just a pure watch URL is unambiguous.
        return lower.contains("list=")
    }

    /// Expands a playlist URL into individual queue items by *streaming*
    /// entries from yt-dlp as they arrive, instead of waiting for the
    /// whole playlist to be dumped at the end. The placeholder is
    /// removed on the very first entry so the user sees items appear
    /// about a second after pasting, instead of staring at a static
    /// loading label for several seconds.
    ///
    /// Creates a `PlaylistGroup` on the first entry using that entry's
    /// `playlist_title` field (or a fallback if yt-dlp didn't emit
    /// one). Every item added during this expansion is tagged with
    /// the group's id so the UI renders them together under a
    /// collapsible header.
    ///
    /// On failure, the placeholder is flipped into an error state.
    private func expandPlaylist(url: String, placeholder: VideoItem) async {
        var addedItems: [VideoItem] = []
        var placeholderDropped = false
        var groupId: UUID?

        do {
            for try await entry in Metadata.streamPlaylistEntries(url: url) {
                // Skip entries the user already has in the queue so
                // re-pasting a playlist doesn't duplicate everything.
                if items.contains(where: { $0.url == entry.url }) { continue }

                // First real entry: drop the placeholder and register
                // the playlist group using whatever title yt-dlp gave
                // us in this entry's JSON.
                if !placeholderDropped {
                    items.removeAll { $0.id == placeholder.id }
                    placeholderDropped = true

                    let group = PlaylistGroup(
                        title: entry.playlistTitle ?? fallbackPlaylistTitle(for: url),
                        sourceURL: url
                    )
                    groupId = group.id
                    groups[group.id] = group
                }

                let item = VideoItem(url: entry.url, defaultQuality: defaultQuality)
                item.groupId = groupId
                item.applyPreliminary(
                    title: entry.title ?? "(unbenannt)",
                    thumbnail: entry.thumbnail,
                    duration: entry.duration,
                    id: entry.id,
                    webpageURL: URL(string: entry.url)
                )
                items.append(item)
                addedItems.append(item)

                // Live-updated running tally — feels more alive than
                // a silent "Playlist wird geladen…" label while the
                // rest of the entries are still streaming in.
                statusLine = addedItems.count == 1
                    ? "1 Video aus Playlist geladen…"
                    : "\(addedItems.count) Videos aus Playlist geladen…"
            }
        } catch {
            // If the stream errored before we got any entries, the
            // placeholder is still there — flip it into an error.
            // If we already dropped the placeholder and some items are
            // in the list, just leave them and show a status warning.
            if !placeholderDropped {
                placeholder.state = .error(error.localizedDescription)
                statusLine = "Playlist konnte nicht geladen werden."
            } else {
                statusLine = "Playlist nur teilweise geladen: \(addedItems.count) Videos."
            }
            return
        }

        // Stream completed cleanly. Finalize the status line and kick
        // off background enrichment for the full metadata.
        if addedItems.isEmpty {
            // Edge case: yt-dlp returned zero entries but didn't error.
            // Leave the placeholder alone and flip it to an error so
            // the user isn't left staring at an empty loading row.
            if !placeholderDropped {
                placeholder.state = .error("Playlist ist leer.")
            }
            if let gid = groupId {
                groups.removeValue(forKey: gid)
            }
            statusLine = "Playlist ist leer."
            return
        }

        statusLine = addedItems.count == 1
            ? "1 Video aus Playlist hinzugefügt."
            : "\(addedItems.count) Videos aus Playlist hinzugefügt."

        // Kick off throttled background enrichment so the quality
        // picker eventually gets real heights. Limited to a few
        // parallel yt-dlp processes so we don't spawn 50 Python
        // interpreters at once.
        Task { await self.enrichMetadata(for: addedItems) }
    }

    /// Last-resort title used when yt-dlp didn't emit a `playlist_title`
    /// field for a flat-playlist entry. Picks a host-based label so
    /// the group header at least says something useful.
    nonisolated static func fallbackPlaylistTitle(for url: String) -> String {
        if let host = URL(string: url)?.host {
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return "Playlist · \(cleanHost)"
        }
        return "Playlist"
    }

    /// Instance-level convenience wrapper so the non-static call sites
    /// stay compact.
    private func fallbackPlaylistTitle(for url: String) -> String {
        Self.fallbackPlaylistTitle(for: url)
    }

    /// Background enrichment for playlist items that already have a
    /// preliminary `info` from the flat-playlist step. Replaces each
    /// item's partial info with the full `--dump-json` result so the
    /// quality picker gains real height options and the thumbnail
    /// upgrades to the higher-resolution version when available.
    ///
    /// Throttled to `maxEnrich` concurrent fetches: yt-dlp is a Python
    /// interpreter that takes ~1 s to start cold, and spawning 30+ of
    /// them at once thrashes the system hard. Four in flight is enough
    /// to overlap network I/O without turning the Mac into a fan.
    ///
    /// Failures are silent — the item is already `.ready` with its
    /// preliminary info, so a failed enrichment just means the quality
    /// picker stays limited to "best" and "audio_mp3" for that row.
    private func enrichMetadata(for items: [VideoItem]) async {
        let maxEnrich = 4
        await withTaskGroup(of: Void.self) { group in
            var iter = items.makeIterator()
            var inFlight = 0
            while inFlight < maxEnrich, let next = iter.next() {
                let item = next
                group.addTask { [weak self] in
                    await self?.enrichOne(item)
                }
                inFlight += 1
            }
            while await group.next() != nil {
                if let next = iter.next() {
                    let item = next
                    group.addTask { [weak self] in
                        await self?.enrichOne(item)
                    }
                }
            }
        }
    }

    /// Fetches full metadata for a single already-ready item and
    /// replaces its partial info in place. If the user had a saved
    /// default quality (e.g. "1080p") that is now actually offered by
    /// the video, switches the selection back to it.
    private func enrichOne(_ item: VideoItem) async {
        // Skip if the user cancelled the item between `applyPreliminary`
        // and this fetch running.
        guard items.contains(where: { $0.id == item.id }) else { return }
        do {
            let info = try await Metadata.fetch(url: item.url)
            // Still there? The user could have removed the row while
            // yt-dlp was running.
            guard items.contains(where: { $0.id == item.id }) else { return }
            item.info = info

            let valid = Set(item.qualityOptions.map(\.key))
            if valid.contains(defaultQuality) {
                item.selectedQuality = defaultQuality
            } else if !valid.contains(item.selectedQuality) {
                item.selectedQuality = "best"
            }
        } catch {
            // Silent: the item is still usable with the preliminary info
            // that was set during `applyPreliminary`.
        }
    }

    /// Lightweight heuristic: does this URL *look* like a playlist that
    /// should be expanded, or a single video that should be queued as-is?
    ///
    /// Important: YouTube's `watch?v=X&list=Y` (a video that happens to
    /// be inside a playlist context) is intentionally treated as a single
    /// video — the user pasted the video, not the playlist. Only pure
    /// playlist URLs (`/playlist?list=`) are expanded. For non-YouTube
    /// sites we recognize a few common playlist patterns; everything
    /// else falls through to the single-video path.
    nonisolated static func urlLooksLikePlaylist(_ url: String) -> Bool {
        let lower = url.lowercased()

        // YouTube "watch" / "shorts" → always treat as single video, even
        // if the URL carries a playlist list= parameter.
        if lower.contains("/watch?") || lower.contains("/shorts/") {
            return false
        }
        // YouTube pure playlist URL.
        if lower.contains("/playlist?") && lower.contains("list=") {
            return true
        }
        // SoundCloud sets, Bandcamp albums.
        if lower.contains("/sets/") || lower.contains("/album/") {
            return true
        }
        // Vimeo showcases.
        if lower.contains("/showcase/") {
            return true
        }
        return false
    }

    func remove(_ item: VideoItem) {
        let removedGroupId = item.groupId

        // Remove from the visible list first — this also makes any in-flight
        // downloadOne() task notice that the item is gone and short-circuit.
        items.removeAll { $0.id == item.id }

        // If a yt-dlp process is currently running for this item, terminate
        // it so we don't keep writing bytes to disk after the user cancelled.
        if let process = activeProcesses.removeValue(forKey: item.id) {
            process.terminate()
        }

        // If this was the last item of its group, drop the empty
        // group header so the UI doesn't show a zero-item section.
        if let gid = removedGroupId,
           !items.contains(where: { $0.groupId == gid }) {
            groups.removeValue(forKey: gid)
        }

        updateDockProgress()
        stopSmootherIfIdle()
    }

    /// Removes every item belonging to a playlist group and drops
    /// the group itself. Cancels any in-flight downloads for those
    /// items so we don't keep yt-dlp processes writing bytes to disk
    /// after the user told us not to.
    func removeGroup(_ groupId: UUID) {
        let doomed = items.filter { $0.groupId == groupId }
        for item in doomed {
            if let process = activeProcesses.removeValue(forKey: item.id) {
                process.terminate()
            }
        }
        items.removeAll { $0.groupId == groupId }
        groups.removeValue(forKey: groupId)
        updateDockProgress()
        stopSmootherIfIdle()
    }

    /// Sets the same `selectedQuality` on every item in the group.
    /// yt-dlp's format spec treats heights as "up to N", so setting
    /// `1080p` works even on videos that don't have 1080p available
    /// — they just download the best ≤ 1080p.
    func setGroupQuality(_ groupId: UUID, quality: String) {
        for item in items where item.groupId == groupId {
            item.selectedQuality = quality
        }
    }

    /// Aggregates the progress of all currently active items and pushes it
    /// to the Dock tile. Reads `displayedProgress` so the dock bar follows
    /// the same smoothed motion as the in-window bars.
    func updateDockProgress() {
        let active = items.filter { item in
            switch item.state {
            case .downloading, .postprocessing: return true
            default: return false
            }
        }
        if active.isEmpty {
            DockProgressView.shared.progress = 0
            return
        }
        let sum = active.map(\.displayedProgress).reduce(0, +)
        DockProgressView.shared.progress = sum / Double(active.count)
    }

    // MARK: - Smoother

    /// Starts the 30 fps interpolation timer if it isn't already running.
    private func ensureSmootherRunning() {
        guard smootherTimer == nil else { return }
        let timer = Timer(timeInterval: Self.smootherInterval, repeats: true) { [weak self] _ in
            // Timer fires on the main RunLoop, but the closure isn't main-
            // actor-isolated. Hop onto the actor to touch self.
            Task { @MainActor [weak self] in
                self?.smootherTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        smootherTimer = timer
    }

    /// Stops the smoother if no item is in a state that needs interpolation.
    private func stopSmootherIfIdle() {
        let anyActive = items.contains { item in
            switch item.state {
            case .downloading, .postprocessing: return true
            default: return false
            }
        }
        if !anyActive {
            smootherTimer?.invalidate()
            smootherTimer = nil
        }
    }

    /// One frame of interpolation. Moves each active item's
    /// `displayedProgress` toward its `progress` target with a velocity
    /// chosen to feel responsive without being jumpy.
    private func smootherTick() {
        let dt = Self.smootherInterval
        var anyMoved = false
        for item in items {
            let velocity: Double
            switch item.state {
            case .downloading:    velocity = Self.catchUpVelocity
            case .postprocessing: velocity = Self.postprocessVelocity
            default: continue
            }
            let target = item.progress
            let delta = target - item.displayedProgress
            // Tiny epsilon to avoid an endless tail of micro-updates that
            // never quite reach the target due to FP rounding.
            if delta > 0.0005 {
                let step = min(delta, velocity * dt)
                item.displayedProgress = min(target, item.displayedProgress + step)
                anyMoved = true
            }
        }
        if anyMoved {
            updateDockProgress()
        }
    }

    private func fetchInfo(for item: VideoItem) async {
        do {
            let info = try await Metadata.fetch(url: item.url)
            item.info = info
            // Pick a sensible default quality if the remembered one isn't offered
            let valid = Set(item.qualityOptions.map(\.key))
            if !valid.contains(item.selectedQuality) {
                item.selectedQuality = "best"
            }
            item.state = .ready
        } catch {
            item.state = .error(error.localizedDescription)
        }
    }

    /// Awaits a previously-kicked-off single-video prefetch task and
    /// drops the result into an already-created placeholder item.
    /// Same shape as `fetchInfo(for:)`, just consumes a cached Task
    /// instead of spawning a fresh yt-dlp subprocess. On failure,
    /// falls back to a fresh `fetchInfo` call so the user never gets
    /// stuck with a loading row.
    private func consumeCachedSingle(
        task: Task<Metadata.Info, Error>,
        for item: VideoItem
    ) async {
        do {
            let info = try await task.value
            // The user could have removed the row between the paste
            // and the prefetch resolving.
            guard items.contains(where: { $0.id == item.id }) else { return }
            item.info = info
            let valid = Set(item.qualityOptions.map(\.key))
            if !valid.contains(item.selectedQuality) {
                item.selectedQuality = "best"
            }
            item.state = .ready
        } catch {
            // Cache came back empty or errored — do a fresh fetch so
            // the user still sees proper metadata.
            guard items.contains(where: { $0.id == item.id }) else { return }
            await fetchInfo(for: item)
        }
    }

    // MARK: - Batch download

    func startDownload() {
        guard !isBatchRunning else { return }
        let targets = items.filter {
            if case .ready = $0.state { return true } else { return false }
        }
        guard !targets.isEmpty else { return }

        isBatchRunning = true
        for t in targets {
            t.state = .downloading
            t.progress = 0
            t.displayedProgress = 0
            t._streamTotals = [:]
            t._streamDone = [:]
            t.statusLine = Localization.shared.str(.waiting)
        }
        ensureSmootherRunning()
        updateDockProgress()
        let parallelInfo = min(maxParallel, targets.count)
        statusLine = parallelInfo > 1
            ? "Lade \(targets.count) Videos (\(parallelInfo) parallel)…"
            : "Lade \(targets.count) Video\(targets.count == 1 ? "" : "s")…"

        let plannedOutput = outputDir
        Task { [weak self] in
            await self?.runBatch(targets: targets, outputDir: plannedOutput)
        }
    }

    private func runBatch(targets: [VideoItem], outputDir: String) async {
        var success = 0
        var failed = 0

        await withTaskGroup(of: Bool.self) { group in
            var inFlight = 0
            var iter = targets.makeIterator()

            // seed up to maxParallel tasks
            while inFlight < maxParallel, let next = iter.next() {
                group.addTask { [weak self] in
                    await self?.downloadOne(next, outputDir: outputDir) ?? false
                }
                inFlight += 1
            }

            // as each completes, start the next one
            while let ok = await group.next() {
                if ok { success += 1 } else { failed += 1 }
                if let next = iter.next() {
                    group.addTask { [weak self] in
                        await self?.downloadOne(next, outputDir: outputDir) ?? false
                    }
                } else {
                    inFlight -= 1
                }
            }
        }

        isBatchRunning = false
        if failed == 0 {
            statusLine = "Fertig: \(success) von \(targets.count) heruntergeladen."
        } else {
            statusLine = "Fertig: \(success) ok, \(failed) Fehler (von \(targets.count))."
        }
        updateDockProgress()
        stopSmootherIfIdle()
    }

    // MARK: - Single download

    /// Outcome of a single yt-dlp run.
    private enum RunOutcome {
        /// Download completed successfully.
        case success
        /// User cancelled mid-download (removed the item from the list).
        case cancelled
        /// yt-dlp exited non-zero. The associated stderr is raw; callers
        /// use `ErrorMapper` to turn it into something a human can read.
        case failed(stderr: String, exitCode: Int32)
    }

    /// Outer retry loop around `runYtDlpOnce`. Transient failures
    /// (network, 429, fragment timeouts) are retried up to 2 extra times
    /// with a short backoff. Terminal failures (private video, not
    /// available, bad URL, unsupported site, …) fail on the first try.
    ///
    /// Returns true on success, false on failure or cancellation.
    private nonisolated func downloadOne(_ item: VideoItem, outputDir: String) async -> Bool {
        let bin = ToolLocator.ytDlp()
        guard !bin.isEmpty else {
            await MainActor.run { item.state = .error("yt-dlp nicht gefunden.") }
            return false
        }

        let (quality, customTitle, videoId) = await MainActor.run {
            (item.selectedQuality, item.customTitle, item.info?.id)
        }
        let format = Self.formatSpec(for: quality)
        let outputTemplate = Self.outputTemplate(customTitle: customTitle)

        try? FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true
        )

        let maxAttempts = 3  // initial try + 2 retries
        var lastError: (stderr: String, code: Int32) = ("", 0)
        // Extra yt-dlp args for the *next* attempt. Empty on the first
        // run; populated by the retry logic when we detect a specific
        // failure mode that has a known workaround (e.g. YouTube's
        // bot-check gate → alternative player_client).
        var extraArgs: [String] = []

        for attempt in 1...maxAttempts {
            // On retries, reset progress so the bar starts from 0 again
            // and the user can see something is actually happening.
            if attempt > 1 {
                await MainActor.run {
                    item.progress = 0
                    item.displayedProgress = 0
                    item._streamTotals = [:]
                    item._streamDone = [:]
                    item.state = .downloading
                    item.statusLine = "Neuer Versuch (\(attempt)/\(maxAttempts))…"
                }
                // Short backoff: 2 s, then 5 s. Keeps the retry tight
                // enough that the user doesn't think the app hung, but
                // long enough to get past a transient 429 or network
                // blip.
                let delay: UInt64 = attempt == 2 ? 2_000_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }

            let outcome = await runYtDlpOnce(
                item: item,
                bin: bin,
                format: format,
                outputTemplate: outputTemplate,
                outputDir: outputDir,
                videoId: videoId,
                extraArgs: extraArgs
            )

            switch outcome {
            case .success:
                return true
            case .cancelled:
                return false
            case .failed(let stderr, let code):
                lastError = (stderr, code)
                // YouTube's bot-check gate has a specific workaround:
                // switch to the tv_embedded player client on the next
                // attempt. Classified as transient via ErrorMapper, so
                // the fall-through below keeps retrying; we just need
                // to set the extraArgs so the next run uses them.
                if ErrorMapper.isYouTubeBotCheck(stderr: stderr) {
                    extraArgs = Metadata.youtubeBotCheckRetryArgs
                }
                // Only retry if the error looks transient. Terminal
                // errors (private, unavailable, login-required, …) fail
                // immediately with a friendly message.
                if !ErrorMapper.isTransient(stderr: stderr) {
                    break
                }
                if attempt == maxAttempts {
                    break
                }
                // continue to next attempt
                continue
            }
            break
        }

        // All attempts exhausted — surface a friendly error message.
        let friendly = ErrorMapper.friendlyMessage(
            stderr: lastError.stderr,
            exitCode: lastError.code
        )
        await MainActor.run {
            item.state = .error(friendly)
            item.progress = 0
            item.displayedProgress = 0
            self.stopSmootherIfIdle()
        }
        return false
    }

    /// One single yt-dlp invocation — no retries. Returns a `RunOutcome`
    /// describing what happened; the outer `downloadOne` decides whether
    /// to retry.
    ///
    /// `extraArgs` is forwarded verbatim into the yt-dlp argv. The
    /// retry loop in `downloadOne` uses this to inject workarounds
    /// like the tv_embedded player_client when the first attempt hits
    /// YouTube's bot-check gate.
    private nonisolated func runYtDlpOnce(
        item: VideoItem,
        bin: String,
        format: String,
        outputTemplate: String,
        outputDir: String,
        videoId: String?,
        extraArgs: [String] = []
    ) async -> RunOutcome {
        let quality = await MainActor.run { item.selectedQuality }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        var args: [String] = [
            "--no-playlist",
            "--no-warnings",
            "--newline",
            "--concurrent-fragments", "4",
            "--retries", "5",
            "--fragment-retries", "5",
            "--merge-output-format", "mp4",
            "--paths", outputDir,
            "-o", outputTemplate,
            "-f", format,
            // Structured progress lines — easy to parse.
            "--progress-template",
            "download:DL|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.format_id)s",
            // Print the final on-disk path after yt-dlp has moved/merged
            // the file to its definitive location. Used so we can reveal
            // the file in Finder when the user clicks the notification.
            "--print", "after_move:FINAL_FILE:%(filepath)s",
            // `--print` implies `--quiet`, which would suppress every
            // progress update. Undo that so our progress template keeps
            // streaming.
            "--no-quiet",
        ]
        // Audio extraction uses a postprocessor
        if quality == "audio_mp3" {
            args.append(contentsOf: [
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", "192K",
            ])
        }
        // Caller-supplied extras (e.g. bot-check retry workaround).
        args.append(contentsOf: extraArgs)
        args.append(item.url)
        process.arguments = args

        // Prepend the app bundle's bin/ dir to PATH so yt-dlp finds the
        // bundled ffmpeg without relying on Homebrew. Homebrew's path is
        // kept as a fallback for users running the debug build.
        var env = ProcessInfo.processInfo.environment
        var pathParts: [String] = []
        if let bundled = ToolLocator.bundledBinDir {
            pathParts.append(bundled)
        }
        pathParts.append("/opt/homebrew/bin")
        pathParts.append(env["PATH"] ?? "/usr/bin:/bin")
        env["PATH"] = pathParts.joined(separator: ":")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Stream stdout line-by-line and translate to item updates.
        let parser = ProgressParser()
        let stdoutHandle = stdout.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            parser.feed(chunk) { event in
                Task { @MainActor [weak self] in
                    Self.apply(event: event, to: item)
                    self?.updateDockProgress()
                }
            }
        }

        // If the user already cancelled before we even got here, bail out.
        let stillQueued = await MainActor.run {
            self.items.contains(where: { $0.id == item.id })
        }
        if !stillQueued { return .cancelled }

        do {
            try process.run()
        } catch {
            return .failed(stderr: "Start fehlgeschlagen: \(error.localizedDescription)", exitCode: -1)
        }

        // Register the process so remove() can terminate it.
        // Re-check the item is still in the list to close the race with a
        // remove() that might have run between the check above and now.
        let wasRegistered = await MainActor.run { () -> Bool in
            guard self.items.contains(where: { $0.id == item.id }) else {
                return false
            }
            self.activeProcesses[item.id] = process
            return true
        }
        if !wasRegistered {
            process.terminate()
            process.waitUntilExit()
            stdoutHandle.readabilityHandler = nil
            return .cancelled
        }

        process.waitUntilExit()
        stdoutHandle.readabilityHandler = nil

        // Unregister the process (ignore if remove() already did it).
        let wasCancelled = await MainActor.run { () -> Bool in
            let stillInList = self.items.contains(where: { $0.id == item.id })
            self.activeProcesses.removeValue(forKey: item.id)
            return !stillInList
        }
        if wasCancelled {
            // The user clicked X — clean up any partial files yt-dlp left
            // behind (half-downloaded streams, .part files, .ytdl resume
            // files, etc.) so cancellation doesn't pollute the output dir.
            Self.cleanupPartialFiles(videoId: videoId, in: outputDir)
            return .cancelled
        }

        let code = process.terminationStatus
        if code != 0 {
            let errOut = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Clean up any partial files left behind by the failed run
            // so a retry starts from scratch instead of resuming from a
            // potentially corrupt .part file.
            Self.cleanupPartialFiles(videoId: videoId, in: outputDir)
            return .failed(stderr: errOut, exitCode: code)
        }

        await MainActor.run {
            item.state = .done
            item.progress = 1.0
            item.displayedProgress = 1.0  // snap, the bar will be hidden anyway
            item.statusLine = Localization.shared.str(.doneMark)
            DownloadNotifier.shared.notifyDownloadComplete(
                title: item.title,
                filePath: item.finalFile?.path
            )
            self.updateDockProgress()
            self.stopSmootherIfIdle()
        }
        return .success
    }

    // MARK: - Format spec

    /// Deletes any partial / side files yt-dlp may have left behind for a
    /// cancelled download. Uses the video ID (embedded as `[id]` in every
    /// output filename by our template) as the marker so we don't touch
    /// unrelated files in the output directory.
    nonisolated static func cleanupPartialFiles(videoId: String?, in outputDir: String) {
        guard let id = videoId, !id.isEmpty else { return }
        let marker = "[\(id)]"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: outputDir) else { return }
        for entry in entries where entry.contains(marker) {
            let full = (outputDir as NSString).appendingPathComponent(entry)
            try? fm.removeItem(atPath: full)
        }
    }

    /// Builds the yt-dlp `-o` template. Uses the user's custom title if set,
    /// otherwise falls back to yt-dlp's own `%(title)s`.
    nonisolated static func outputTemplate(customTitle: String?) -> String {
        guard let raw = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "%(title)s [%(id)s].%(ext)s"
        }
        // Sanitize for filesystem + yt-dlp template syntax:
        // - replace path separators and colon
        // - escape % so yt-dlp treats it as literal
        var safe = raw
        for bad in ["/", ":", "\\"] {
            safe = safe.replacingOccurrences(of: bad, with: "_")
        }
        safe = safe.replacingOccurrences(of: "%", with: "%%")
        return "\(safe) [%(id)s].%(ext)s"
    }

    /// Prefers H.264 (avc1) + AAC (m4a) for Adobe/QuickTime compatibility.
    nonisolated static func formatSpec(for quality: String) -> String {
        if quality == "audio_mp3" {
            return "bestaudio/best"
        }
        if quality == "best" {
            return
                "bestvideo[vcodec^=avc1]+bestaudio[ext=m4a]/" +
                "bestvideo[ext=mp4]+bestaudio[ext=m4a]/" +
                "bestvideo*+bestaudio/best"
        }
        if quality.hasSuffix("p"), let h = Int(quality.dropLast()) {
            return
                "bestvideo[vcodec^=avc1][height<=\(h)]+bestaudio[ext=m4a]/" +
                "bestvideo[ext=mp4][height<=\(h)]+bestaudio[ext=m4a]/" +
                "bestvideo[height<=\(h)]+bestaudio/best[height<=\(h)]"
        }
        return "bestvideo*+bestaudio/best"
    }

    // MARK: - Progress event handling

    private static func apply(event: ProgressParser.Event, to item: VideoItem) {
        switch event {
        case .download(let downloaded, let total, let speed, let eta, let formatId):
            // Cumulative byte tracking across video+audio streams so the
            // bar doesn't jump back to 0 when the second stream starts.
            if let total = total, total > 0 {
                item._streamTotals[formatId] = total
            }
            item._streamDone[formatId] = downloaded

            let sumTotal = item._streamTotals.values.reduce(0, +)
            let sumDone = item._streamDone.values.reduce(0, +)
            if sumTotal > 0 {
                let raw = Double(sumDone) / Double(sumTotal)
                // Squeeze real download progress into 0…downloadCeiling
                // (= 0.95). The remaining 5 % is the postprocessing budget.
                let scaled = min(DownloadManager.downloadCeiling,
                                 raw * DownloadManager.downloadCeiling)
                // Monotonic: never let the bar tick backwards if the total
                // is revised upward (e.g. when the audio stream starts).
                item.progress = max(item.progress, scaled)
            }

            let l10n = Localization.shared
            let speedText: String
            if let s = speed, s > 0 {
                let mb = Double(s) / (1024 * 1024)
                speedText = String(format: "%.2f MB/s", mb)
            } else {
                speedText = "–"
            }
            let etaText: String
            if let e = eta, e > 0 {
                etaText = "\(e)s"
            } else {
                etaText = "–"
            }
            item.statusLine = l10n.str(.downloadStatus, speedText, etaText)

        case .postprocess(let kind):
            item.state = .postprocessing
            // Target the very end of the bar so the smoother creeps the
            // remaining ~5 % during merge / remux / audio extraction at
            // postprocessVelocity. Stays monotonic via max().
            item.progress = max(item.progress, 0.99)
            let l10n = Localization.shared
            switch kind {
            case .audio:  item.statusLine = l10n.str(.extractingAudio)
            case .remux:  item.statusLine = l10n.str(.converting)
            case .merge:  item.statusLine = l10n.str(.converting)
            case .other:  item.statusLine = l10n.str(.postprocessing)
            }

        case .finalFile(let path):
            item.finalFile = URL(fileURLWithPath: path)
        }
    }
}

// Extra per-item fields used only for progress tracking.
// Stored as associated keys via extension to keep VideoItem tidy.
private var streamTotalsKey = 0
private var streamDoneKey = 0
extension VideoItem {
    var _streamTotals: [String: Int64] {
        get { (objc_getAssociatedObject(self, &streamTotalsKey) as? [String: Int64]) ?? [:] }
        set { objc_setAssociatedObject(self, &streamTotalsKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    var _streamDone: [String: Int64] {
        get { (objc_getAssociatedObject(self, &streamDoneKey) as? [String: Int64]) ?? [:] }
        set { objc_setAssociatedObject(self, &streamDoneKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}

// MARK: - Progress parser

/// Parses yt-dlp stdout one line at a time and emits typed events.
final class ProgressParser: @unchecked Sendable {
    enum Event {
        enum PPKind { case audio, remux, merge, other }
        case download(downloaded: Int64, total: Int64?, speed: Int64?, eta: Int?, formatId: String)
        case postprocess(PPKind)
        case finalFile(String)
    }

    private var buffer = ""

    func feed(_ chunk: String, emit: (Event) -> Void) {
        buffer += chunk
        while let nl = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if let ev = Self.parse(line: line) {
                emit(ev)
            }
        }
    }

    private static func parse(line raw: String) -> Event? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }

        // Final file path from `--print after_move:FINAL_FILE:...`
        if line.hasPrefix("FINAL_FILE:") {
            let path = String(line.dropFirst("FINAL_FILE:".count))
                .trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : .finalFile(path)
        }

        // Custom progress template
        if line.hasPrefix("DL|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            // parts: ["DL", downloaded, total, total_estimate, speed, eta, format_id]
            if parts.count >= 7 {
                let downloaded = Int64(parts[1]) ?? 0
                let total = Int64(parts[2]) ?? Int64(parts[3]) ?? nil
                let speed = Int64(Double(parts[4]) ?? 0)
                let eta = Int(Double(parts[5]) ?? 0)
                let formatId = parts[6].isEmpty ? "stream" : parts[6]
                return .download(
                    downloaded: downloaded,
                    total: total,
                    speed: speed > 0 ? speed : nil,
                    eta: eta > 0 ? eta : nil,
                    formatId: formatId
                )
            }
        }

        // Postprocessor prefixes
        if line.contains("[ExtractAudio]") { return .postprocess(.audio) }
        if line.contains("[VideoRemuxer]") || line.contains("[Remuxer]") {
            return .postprocess(.remux)
        }
        if line.contains("[Merger]") { return .postprocess(.merge) }
        if line.hasPrefix("[") && line.contains("Destination:") {
            return .postprocess(.other)
        }

        return nil
    }
}
