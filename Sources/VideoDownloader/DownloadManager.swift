import Foundation
import Observation

/// Orchestrates yt-dlp downloads: builds the format spec, spawns the process,
/// parses its progress output, and updates per-item state on the main actor.
@MainActor
@Observable
final class DownloadManager {

    var items: [VideoItem] = []
    var outputDir: String
    var statusLine: String = ""
    var isBatchRunning: Bool = false

    /// Last-picked quality, applied as the default for newly added items.
    var defaultQuality: String

    private let maxParallel = 3

    /// Running yt-dlp processes keyed by item ID. Used to cancel a specific
    /// item's download when the user clicks X.
    private var activeProcesses: [UUID: Process] = [:]

    init(config: AppConfig) {
        self.outputDir = config.outputDir
        self.defaultQuality = config.defaultQuality
    }

    // MARK: - Queue management

    func add(url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            statusLine = "Bitte eine vollständige URL eingeben."
            return
        }
        if items.contains(where: { $0.url == trimmed }) {
            statusLine = "Diese URL ist schon in der Liste."
            return
        }

        let item = VideoItem(url: trimmed, defaultQuality: defaultQuality)
        items.append(item)
        statusLine = "Bereit."

        Task { await self.fetchInfo(for: item) }
    }

    func remove(_ item: VideoItem) {
        // Remove from the visible list first — this also makes any in-flight
        // downloadOne() task notice that the item is gone and short-circuit.
        items.removeAll { $0.id == item.id }

        // If a yt-dlp process is currently running for this item, terminate
        // it so we don't keep writing bytes to disk after the user cancelled.
        if let process = activeProcesses.removeValue(forKey: item.id) {
            process.terminate()
        }

        updateDockProgress()
    }

    /// Aggregates the progress of all currently active items and pushes it
    /// to the Dock tile. Call this after any state or progress change.
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
        let sum = active.map(\.progress).reduce(0, +)
        DockProgressView.shared.progress = sum / Double(active.count)
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
            t.statusLine = Localization.shared.str(.waiting)
        }
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
    }

    // MARK: - Single download

    /// Runs yt-dlp for one item and parses its stdout for progress.
    /// Returns true on success, false on failure.
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
        if !stillQueued { return false }

        do {
            try process.run()
        } catch {
            await MainActor.run { item.state = .error("Start fehlgeschlagen: \(error.localizedDescription)") }
            return false
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
            return false
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
            return false
        }

        let code = process.terminationStatus
        if code != 0 {
            let errOut = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let firstLine = errOut.split(separator: "\n").first.map(String.init) ?? "yt-dlp beendet mit Code \(code)"
            await MainActor.run {
                item.state = .error(firstLine)
                item.progress = 0
            }
            return false
        }

        await MainActor.run {
            item.state = .done
            item.progress = 1.0
            item.statusLine = Localization.shared.str(.doneMark)
            DownloadNotifier.shared.notifyDownloadComplete(
                title: item.title,
                filePath: item.finalFile?.path
            )
            self.updateDockProgress()
        }
        return true
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
                item.progress = min(1.0, Double(sumDone) / Double(sumTotal))
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
