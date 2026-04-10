import Foundation

/// Wraps `yt-dlp --dump-json` to fetch metadata for a single URL.
enum Metadata {

    struct Info: Equatable, Hashable {
        let id: String
        let title: String
        let duration: Int?     // seconds
        let thumbnail: URL?
        let uploader: String?
        let webpageURL: URL?
        /// Distinct video heights available (for the per-item quality picker)
        let heights: [Int]
    }

    // MARK: - Playlist detection

    /// One video inside a playlist, as returned by yt-dlp's
    /// `--flat-playlist` mode. URL is mandatory; everything else is
    /// best-effort data we opportunistically pull from the flat-dump
    /// so the UI can show titles and thumbnails immediately, without
    /// waiting for the expensive per-video metadata fetch.
    ///
    /// `playlistTitle` is the parent playlist's display name, which
    /// yt-dlp propagates into every flat entry's JSON. The first
    /// entry's value is used as the group header in the UI.
    struct PlaylistEntry {
        let url: String
        let title: String?
        let thumbnail: URL?
        let duration: Int?
        let id: String?
        let playlistTitle: String?
    }

    /// Result of `checkPlaylist`.
    enum PlaylistCheck {
        case single
        case playlist(title: String?, entries: [PlaylistEntry])
    }

    // MARK: Raw decoder types

    private struct RawInfo: Decodable {
        let id: String?
        let title: String?
        let duration: Double?
        let thumbnail: String?
        let uploader: String?
        let webpage_url: String?
        let formats: [RawFormat]?
    }

    private struct RawFormat: Decodable {
        let height: Int?
        let vcodec: String?
    }

    enum FetchError: Error, LocalizedError {
        case binaryMissing
        case ytDlpFailed(String)
        case decodingFailed
        var errorDescription: String? {
            switch self {
            case .binaryMissing: return "yt-dlp wurde nicht gefunden."
            case .ytDlpFailed(let msg): return msg
            case .decodingFailed: return "Antwort von yt-dlp konnte nicht gelesen werden."
            }
        }
    }

    /// Extra yt-dlp arguments used on retry when YouTube's bot-check
    /// gate kicks in. The `tv_embedded` player client typically
    /// bypasses the check, with the normal default clients as a
    /// fallback in case tv_embedded also misbehaves for a given URL.
    static let youtubeBotCheckRetryArgs: [String] = [
        "--extractor-args",
        "youtube:player_client=tv_embedded,default"
    ]

    /// Runs `yt-dlp --dump-json --no-playlist <url>` in the background
    /// and returns the parsed, slimmed-down Info.
    ///
    /// Transparently retries once with an alternative YouTube player
    /// client if the first attempt hits YouTube's "sign in to confirm
    /// you're not a bot" gate.
    static func fetch(url: String) async throws -> Info {
        do {
            return try await fetchOnce(url: url, extraArgs: [])
        } catch let error as FetchError {
            if case .ytDlpFailed(let msg) = error, ErrorMapper.isYouTubeBotCheck(stderr: msg) {
                // Bot-check gate triggered. Retry immediately with the
                // tv_embedded player client — almost always bypasses it.
                return try await fetchOnce(url: url, extraArgs: youtubeBotCheckRetryArgs)
            }
            throw error
        }
    }

    /// One-shot metadata fetch. Public API goes through `fetch(url:)`
    /// which handles the bot-check retry; this is the inner building
    /// block that actually spawns yt-dlp.
    private static func fetchOnce(url: String, extraArgs: [String]) async throws -> Info {
        let bin = ToolLocator.ytDlp()
        guard !bin.isEmpty else { throw FetchError.binaryMissing }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = [
                "--dump-json",
                "--no-playlist",
                "--no-warnings",
                "--quiet",
            ] + extraArgs + [
                url,
            ]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            // IMPORTANT: drain stdout/stderr BEFORE waitUntilExit.
            // yt-dlp's JSON dump can exceed the pipe buffer (16-64 KB on
            // macOS); if the buffer fills before we read, yt-dlp blocks on
            // write and waitUntilExit() deadlocks.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()

            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let err = String(data: errData, encoding: .utf8) ?? ""
                throw FetchError.ytDlpFailed(err.isEmpty ? "yt-dlp failed" : err)
            }

            guard let raw = try? JSONDecoder().decode(RawInfo.self, from: data) else {
                throw FetchError.decodingFailed
            }

            let rawHeights = (raw.formats ?? [])
                .filter { ($0.vcodec ?? "none") != "none" }
                .compactMap(\.height)
            let heights = Array(Set(rawHeights)).sorted(by: >)

            return Info(
                id: raw.id ?? "",
                title: raw.title ?? raw.id ?? "Unbekannt",
                duration: raw.duration.map { Int($0) },
                thumbnail: raw.thumbnail.flatMap(URL.init(string:)),
                uploader: raw.uploader,
                webpageURL: raw.webpage_url.flatMap(URL.init(string:)),
                heights: heights
            )
        }.value
    }

    /// Decides whether a URL is a single video or a playlist.
    ///
    /// Uses `yt-dlp --flat-playlist -J` which is cheap — it only lists
    /// the playlist's items (IDs, titles, URLs) without fetching per-
    /// video metadata. A 100-video playlist resolves in a few seconds
    /// instead of the ~1 minute a full per-video dump would take.
    ///
    /// Returns:
    /// - `.single` — the URL is a single video, caller should use the
    ///   existing `fetch(url:)` path.
    /// - `.playlist(title, entries)` — the URL resolved to a playlist
    ///   with N entries; caller should add one queue item per entry.
    static func checkPlaylist(url: String) async throws -> PlaylistCheck {
        let bin = ToolLocator.ytDlp()
        guard !bin.isEmpty else { throw FetchError.binaryMissing }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bin)
            process.arguments = [
                "--flat-playlist",
                "-J",                  // --dump-single-json
                "--no-warnings",
                "--quiet",
                url,
            ]

            // Same PATH prep as the download path: make sure the bundled
            // ffmpeg dir (and Homebrew) is visible to the child process.
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

            try process.run()

            // Drain before waitUntilExit so the pipe buffer can't deadlock
            // us on a big playlist dump.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let err = String(data: errData, encoding: .utf8) ?? ""
                throw FetchError.ytDlpFailed(err.isEmpty ? "yt-dlp failed" : err)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FetchError.decodingFailed
            }

            // yt-dlp marks multi-entry containers with `_type = "playlist"`
            // or `_type = "multi_video"`. Anything else is a single video.
            let type = json["_type"] as? String
            guard type == "playlist" || type == "multi_video" else {
                return .single
            }

            let playlistTitle = json["title"] as? String
            let rawEntries = (json["entries"] as? [[String: Any]]) ?? []

            var entries: [PlaylistEntry] = []
            entries.reserveCapacity(rawEntries.count)

            for entry in rawEntries {
                // Prefer the explicit webpage_url (always a full URL when
                // present). Fall back to `url`, which may be a full URL
                // or — for YouTube — just a video ID that we need to
                // wrap into a watch URL manually.
                let resolved: String?
                if let webURL = entry["webpage_url"] as? String, !webURL.isEmpty {
                    resolved = webURL
                } else if let rawURL = entry["url"] as? String, !rawURL.isEmpty {
                    if rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://") {
                        resolved = rawURL
                    } else {
                        // yt-dlp's flat-playlist for YouTube hands back
                        // bare video IDs in the `url` field. Reconstruct
                        // a real watch URL so the per-item path works.
                        let ieKey = (entry["ie_key"] as? String) ?? ""
                        if ieKey.lowercased().contains("youtube") || ieKey.isEmpty {
                            resolved = "https://www.youtube.com/watch?v=\(rawURL)"
                        } else {
                            resolved = nil  // unknown extractor, give up
                        }
                    }
                } else {
                    resolved = nil
                }

                guard let finalURL = resolved else { continue }

                let title = entry["title"] as? String
                let id = entry["id"] as? String

                // Duration is usually an int but some extractors emit a
                // float. Normalize both.
                let duration: Int?
                if let d = entry["duration"] as? Int {
                    duration = d
                } else if let d = entry["duration"] as? Double {
                    duration = Int(d)
                } else {
                    duration = nil
                }

                // Thumbnail: flat-playlist can emit either a single
                // "thumbnail" string or a "thumbnails" array of
                // {url, width, height} dicts. Pick the largest by
                // pixel area when we have a choice — it looks better
                // when the card view downsamples it.
                let thumbnail: URL? = extractBestThumbnail(from: entry)

                entries.append(PlaylistEntry(
                    url: finalURL,
                    title: title,
                    thumbnail: thumbnail,
                    duration: duration,
                    id: id,
                    playlistTitle: playlistTitle
                ))
            }

            return .playlist(title: playlistTitle, entries: entries)
        }.value
    }

    /// Streams playlist entries from yt-dlp one at a time, as they're
    /// discovered, instead of waiting for the whole playlist to be
    /// enumerated and dumped at the end.
    ///
    /// Transparently retries with an alternative YouTube player
    /// client if the first attempt hits the bot-check gate before
    /// yielding any entries. The retry is only attempted if the
    /// first attempt yielded zero entries — otherwise the partial
    /// result is surfaced as-is, because retrying would produce
    /// duplicates in the consumer's output.
    static func streamPlaylistEntries(url: String) -> AsyncThrowingStream<PlaylistEntry, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                var yieldedCount = 0
                var firstError: Error?

                // First attempt: default player clients.
                do {
                    for try await entry in streamPlaylistEntriesOnce(url: url, extraArgs: []) {
                        continuation.yield(entry)
                        yieldedCount += 1
                    }
                    continuation.finish()
                    return
                } catch {
                    firstError = error
                }

                // If we already gave the consumer some entries, don't
                // retry — the duplicates would be worse than the error.
                if yieldedCount > 0 {
                    continuation.finish(throwing: firstError!)
                    return
                }

                // Zero entries and a bot-check error → retry with the
                // tv_embedded player client. Any other error → give up.
                if let err = firstError as? FetchError,
                   case .ytDlpFailed(let msg) = err,
                   ErrorMapper.isYouTubeBotCheck(stderr: msg) {
                    do {
                        for try await entry in streamPlaylistEntriesOnce(
                            url: url,
                            extraArgs: youtubeBotCheckRetryArgs
                        ) {
                            continuation.yield(entry)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                continuation.finish(throwing: firstError!)
            }
        }
    }

    /// One shot of the playlist-entry stream — the inner building
    /// block. `streamPlaylistEntries(url:)` wraps this in a
    /// bot-check retry loop.
    ///
    /// Flags used:
    /// - `-j` emits one JSON object per line (vs. `-J` which wraps
    ///   everything in one big blob at the end — not streamable)
    /// - `--flat-playlist` tells yt-dlp not to recurse into individual
    ///   videos, so each entry is cheap (no format probe, no metadata
    ///   fetch)
    /// - `--lazy-playlist` pages entries from the remote site as it
    ///   goes instead of prefetching the whole list first
    /// - `--ignore-config` skips any user yt-dlp config file that
    ///   could slow startup or change behavior
    /// - `--no-color` keeps stderr clean of ANSI escape codes so our
    ///   error messages don't contain garbage
    private static func streamPlaylistEntriesOnce(
        url: String,
        extraArgs: [String]
    ) -> AsyncThrowingStream<PlaylistEntry, Error> {
        AsyncThrowingStream { continuation in
            let bin = ToolLocator.ytDlp()
            guard !bin.isEmpty else {
                continuation.finish(throwing: FetchError.binaryMissing)
                return
            }

            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: bin)
                process.arguments = [
                    "-j",                  // one JSON per line, streamed
                    "--flat-playlist",
                    "--lazy-playlist",
                    "--ignore-config",
                    "--no-warnings",
                    "--no-color",
                    "--quiet",
                ] + extraArgs + [
                    url,
                ]

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

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                // Drain stdout line-by-line in a blocking loop. Each
                // `availableData` call waits until yt-dlp writes more
                // data or closes the pipe (returns empty → EOF).
                let handle = stdout.fileHandleForReading
                var buffer = Data()

                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF
                    buffer.append(chunk)

                    // Parse every complete line we can find in the buffer.
                    while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<newlineIdx)
                        buffer.removeSubrange(0...newlineIdx)
                        guard !lineData.isEmpty else { continue }
                        if let entry = parseStreamingEntry(from: lineData) {
                            continuation.yield(entry)
                        }
                    }
                }

                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    continuation.finish(throwing: FetchError.ytDlpFailed(
                        err.isEmpty ? "yt-dlp failed" : err
                    ))
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// Parses one line of `yt-dlp -j --flat-playlist` output into a
    /// `PlaylistEntry`. Returns nil if the JSON is malformed or doesn't
    /// carry enough info to build a usable entry (no URL, no ID).
    private static func parseStreamingEntry(from data: Data) -> PlaylistEntry? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Resolve a full URL, handling the YouTube "bare ID" case.
        let resolved: String?
        if let webURL = json["webpage_url"] as? String, !webURL.isEmpty {
            resolved = webURL
        } else if let rawURL = json["url"] as? String, !rawURL.isEmpty {
            if rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://") {
                resolved = rawURL
            } else {
                let ieKey = (json["ie_key"] as? String) ?? ""
                if ieKey.lowercased().contains("youtube") || ieKey.isEmpty {
                    resolved = "https://www.youtube.com/watch?v=\(rawURL)"
                } else {
                    resolved = nil
                }
            }
        } else {
            resolved = nil
        }
        guard let finalURL = resolved else { return nil }

        let title = json["title"] as? String
        let id = json["id"] as? String

        let duration: Int?
        if let d = json["duration"] as? Int {
            duration = d
        } else if let d = json["duration"] as? Double {
            duration = Int(d)
        } else {
            duration = nil
        }

        let thumbnail = extractBestThumbnail(from: json)

        // yt-dlp propagates the parent playlist title into every flat
        // entry's JSON as `playlist_title`. Older versions sometimes
        // use `playlist` instead — accept either.
        let playlistTitle = (json["playlist_title"] as? String)
            ?? (json["playlist"] as? String)

        return PlaylistEntry(
            url: finalURL,
            title: title,
            thumbnail: thumbnail,
            duration: duration,
            id: id,
            playlistTitle: playlistTitle
        )
    }

    /// Picks the highest-resolution thumbnail URL from a yt-dlp JSON
    /// entry. Handles both the old-style `thumbnail` string field and
    /// the newer `thumbnails` array of `{url, width, height}` dicts.
    private static func extractBestThumbnail(from entry: [String: Any]) -> URL? {
        if let thumbs = entry["thumbnails"] as? [[String: Any]], !thumbs.isEmpty {
            let sorted = thumbs.sorted { a, b in
                let aw = (a["width"] as? Int) ?? 0
                let ah = (a["height"] as? Int) ?? 0
                let bw = (b["width"] as? Int) ?? 0
                let bh = (b["height"] as? Int) ?? 0
                return (aw * ah) > (bw * bh)
            }
            for t in sorted {
                if let s = t["url"] as? String, let url = URL(string: s) {
                    return url
                }
            }
        }
        if let s = entry["thumbnail"] as? String, let url = URL(string: s) {
            return url
        }
        return nil
    }
}

/// Locates CLI tools, preferring binaries bundled inside the app.
///
/// yt-dlp ships as a PyInstaller *onedir* build: a launcher binary
/// (`yt-dlp_macos`) sitting next to an `_internal/` directory that
/// holds the embedded Python interpreter and all native libraries.
/// The launcher finds `_internal/` via its own executable path, so
/// the two MUST live together in the same parent directory. We keep
/// both inside a `yt-dlp/` subdirectory to make that invariant obvious.
///
/// ffmpeg stays a single static binary — it doesn't have the Python
/// extraction problem, so the onedir trick isn't needed.
///
/// Priority order for yt-dlp:
///   1. `~/Library/Application Support/VideoDownloader/yt-dlp/yt-dlp_macos`
///      — onedir build refreshed by the background updater.
///   2. `Contents/Resources/bin/yt-dlp/yt-dlp_macos`
///      — onedir shipped with the .app.
///   3. Homebrew / system single-file `yt-dlp` — dev fallback for
///      `swift run`, where there is no bundle.
///
/// Priority order for ffmpeg:
///   1. `Contents/Resources/bin/ffmpeg` — bundled static binary.
///   2. Homebrew / system.
enum ToolLocator {
    private static let systemSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    /// Directory containing the bundled sidecars (`Resources/bin/`),
    /// or nil outside of a proper .app bundle. Used both as a PATH
    /// entry for child processes (so yt-dlp can find ffmpeg) and as
    /// the anchor for locating the bundled yt-dlp onedir.
    static var bundledBinDir: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent("bin", isDirectory: true).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return dir
    }

    /// User-updatable yt-dlp onedir location — written to by
    /// `ToolUpdater`. Points at the *directory*, not the launcher.
    static var userYtDlpDir: String {
        ToolUpdater.userYtDlpDir.path
    }

    // MARK: yt-dlp

    static func ytDlp() -> String {
        // 1. Auto-updated onedir in Application Support.
        let userLauncher = (userYtDlpDir as NSString)
            .appendingPathComponent("yt-dlp_macos")
        if FileManager.default.isExecutableFile(atPath: userLauncher) {
            return userLauncher
        }

        // 2. Bundled onedir: Contents/Resources/bin/yt-dlp/yt-dlp_macos
        if let binDir = bundledBinDir {
            let bundledLauncher = ((binDir as NSString)
                .appendingPathComponent("yt-dlp") as NSString)
                .appendingPathComponent("yt-dlp_macos")
            if FileManager.default.isExecutableFile(atPath: bundledLauncher) {
                return bundledLauncher
            }
        }

        // 3. System single-file fallback for `swift run` / dev builds.
        for p in systemSearchPaths {
            let full = (p as NSString).appendingPathComponent("yt-dlp")
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return ""
    }

    // MARK: ffmpeg

    static func ffmpeg() -> String {
        // 1. Bundled static binary.
        if let binDir = bundledBinDir {
            let bundled = (binDir as NSString).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        // 2. System fallback.
        for p in systemSearchPaths {
            let full = (p as NSString).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return ""
    }
}
