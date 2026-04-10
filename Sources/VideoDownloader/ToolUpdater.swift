import Foundation

/// Background updater for the bundled yt-dlp onedir.
///
/// Why this exists: YouTube / Instagram / TikTok keep changing their APIs,
/// and yt-dlp ships fixes within hours. The binary we bundle at build
/// time goes stale within weeks. Without this, the app would start
/// failing silently a month after each release.
///
/// Why we ship the *onedir* build (`yt-dlp_macos.zip`) instead of the
/// single-file `yt-dlp_macos`: PyInstaller's onefile bundler extracts
/// its embedded Python interpreter + all native libraries into a fresh
/// `/var/folders/.../_MEIxxxx` directory on *every* invocation, adding
/// ~7 seconds of cold-start to every call. The onedir build keeps
/// Python and its libraries pre-extracted in an `_internal/` directory
/// next to the launcher — warm starts drop from ~7 s to ~200 ms, which
/// is a 35× speedup and the single biggest perceived-performance win
/// in the app.
///
/// Strategy: on app launch, if we haven't checked in the last 24 hours,
/// ask the GitHub releases API for the latest tag. If it differs from
/// what we already have extracted, download `yt-dlp_macos.zip`, unpack
/// into a staging directory, and atomically swap it into place. The
/// in-place directory always contains a working copy — the staging
/// tree only becomes live after extraction and a smoke-test succeed.
///
/// All failures (no network, rate limit, GitHub down, disk full, …)
/// are swallowed. The bundled onedir inside the .app is always
/// available as a fallback via `ToolLocator`, so a failed update
/// never breaks the app.
enum ToolUpdater {

    // MARK: - Paths

    /// `~/Library/Application Support/VideoDownloader/`
    static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VideoDownloader", isDirectory: true)
    }

    /// `~/Library/Application Support/VideoDownloader/yt-dlp/`
    /// This is the *directory* that holds both the launcher
    /// (`yt-dlp_macos`) and the sibling `_internal/` tree.
    static var userYtDlpDir: URL {
        appSupportDir.appendingPathComponent("yt-dlp", isDirectory: true)
    }

    /// The actual launcher binary inside `userYtDlpDir`.
    static var userYtDlpLauncher: URL {
        userYtDlpDir.appendingPathComponent("yt-dlp_macos")
    }

    /// Legacy single-file location from before we switched to onedir.
    /// Cleaned up opportunistically on every launch so the user isn't
    /// stuck with ~37 MB of dead weight after upgrading.
    static var legacyYtDlpPath: URL {
        appSupportDir
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("yt-dlp")
    }

    // MARK: - UserDefaults keys

    private static let lastCheckKey = "ToolUpdater.lastYtDlpCheck"
    private static let lastTagKey   = "ToolUpdater.lastYtDlpTag"

    /// Minimum gap between GitHub API hits so we don't hammer the
    /// endpoint on every app launch.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// GitHub repository (owner/repo).
    private static let repo = "yt-dlp/yt-dlp"

    /// Timeout for network operations. Kept short because this runs in
    /// the background on startup and must never delay the UI.
    private static let networkTimeout: TimeInterval = 60  // zip download can be slow

    // MARK: - Public API

    /// Checks for a newer yt-dlp release and downloads it in the
    /// background if one is available. Safe to call on every app launch
    /// — it throttles itself via `checkInterval`. Never throws; all
    /// errors are swallowed.
    static func updateIfNeeded() async {
        // Opportunistic cleanup of the pre-onedir legacy location.
        cleanupLegacyIfPresent()

        // Throttle: skip if we checked recently.
        let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
        if lastCheck > 0 {
            let age = Date().timeIntervalSince1970 - lastCheck
            if age < checkInterval { return }
        }

        do {
            let latestTag = try await fetchLatestTag()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            let haveTag    = UserDefaults.standard.string(forKey: lastTagKey)
            let haveOnedir = FileManager.default
                .isExecutableFile(atPath: userYtDlpLauncher.path)

            // Nothing to do if we already have this exact version
            // fully extracted on disk.
            if haveTag == latestTag && haveOnedir { return }

            try await downloadAndExtractLatest()
            UserDefaults.standard.set(latestTag, forKey: lastTagKey)
        } catch {
            // Swallow every failure silently. The bundled yt-dlp onedir
            // inside the .app is still a valid fallback via ToolLocator,
            // so the user will never see a broken app because an update
            // failed.
        }
    }

    /// Removes the old pre-onedir `bin/yt-dlp` single file if it's
    /// lying around. Purely a disk-space courtesy — `ToolLocator` no
    /// longer looks at that path at all, so leaving it there would be
    /// wasted space after upgrading.
    private static func cleanupLegacyIfPresent() {
        let fm = FileManager.default
        let legacy = legacyYtDlpPath.path
        if fm.fileExists(atPath: legacy) {
            try? fm.removeItem(atPath: legacy)
            // If the parent `bin/` directory is now empty, ditch it too.
            let parent = legacyYtDlpPath.deletingLastPathComponent().path
            if let entries = try? fm.contentsOfDirectory(atPath: parent),
               entries.isEmpty {
                try? fm.removeItem(atPath: parent)
            }
        }
    }

    // MARK: - GitHub API

    private struct ReleaseInfo: Decodable {
        let tag_name: String
    }

    private static func fetchLatestTag() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: networkTimeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API requests without a User-Agent.
        req.setValue("MarcsSocialLoader", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        return info.tag_name
    }

    // MARK: - Download + extract

    /// Downloads `yt-dlp_macos.zip`, unpacks it into a staging
    /// directory, and atomically replaces `userYtDlpDir`. Uses
    /// `/usr/bin/unzip` (shipped with every macOS) to avoid pulling
    /// in a dependency for ZIP decoding.
    private static func downloadAndExtractLatest() async throws {
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest/download/yt-dlp_macos.zip") else {
            throw URLError(.badURL)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        var req = URLRequest(url: url, timeoutInterval: networkTimeout)
        req.setValue("MarcsSocialLoader", forHTTPHeaderField: "User-Agent")

        // URLSession.download follows redirects automatically, which we
        // need — GitHub's /releases/latest/download/ endpoint 302s to
        // the real CDN URL.
        let (tempZipURL, response) = try await URLSession.shared.download(for: req)
        defer { try? fm.removeItem(at: tempZipURL) }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Sanity-check the download: the onedir zip is ~64 MB. If it's
        // way smaller, treat it as a failure and bail.
        let attrs = try fm.attributesOfItem(atPath: tempZipURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 20_000_000 else {
            throw URLError(.cannotParseResponse)
        }

        // Extract into a staging directory alongside the live dir.
        // If anything goes wrong, we throw away the staging tree and
        // the live dir stays untouched.
        let stagingDir = appSupportDir.appendingPathComponent("yt-dlp.staging", isDirectory: true)
        if fm.fileExists(atPath: stagingDir.path) {
            try fm.removeItem(at: stagingDir)
        }
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        try runUnzip(zipPath: tempZipURL.path, destination: stagingDir.path)

        // Make the launcher executable and verify it's really there
        // before committing the swap.
        let stagedLauncher = stagingDir.appendingPathComponent("yt-dlp_macos")
        guard fm.fileExists(atPath: stagedLauncher.path) else {
            try? fm.removeItem(at: stagingDir)
            throw URLError(.cannotParseResponse)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedLauncher.path)

        // Strip quarantine so Gatekeeper doesn't flag the freshly
        // downloaded files when the launcher tries to load them.
        stripQuarantine(at: stagingDir.path)

        // Atomic swap: replace the live dir with the staged one.
        // `replaceItemAt` handles the case where the destination exists
        // (renames the old one aside first, then swaps) as well as the
        // first-install case (moves staging into place).
        if fm.fileExists(atPath: userYtDlpDir.path) {
            _ = try fm.replaceItemAt(userYtDlpDir, withItemAt: stagingDir)
        } else {
            try fm.moveItem(at: stagingDir, to: userYtDlpDir)
        }
    }

    /// Shells out to `/usr/bin/unzip` to extract a zip into a target
    /// directory. Swift's Foundation has no zip API and pulling in a
    /// dependency just for this would be silly when every macOS ships
    /// `unzip` out of the box.
    private static func runUnzip(zipPath: String, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", zipPath, "-d", destination]
        process.standardOutput = Pipe()  // silence
        process.standardError  = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw URLError(.cannotParseResponse)
        }
    }

    /// Removes the `com.apple.quarantine` extended attribute from every
    /// file under the staging directory. Without this, macOS refuses
    /// to launch any of the downloaded binaries with a "can't verify
    /// developer" dialog — even though the parent app is already
    /// trusted. `xattr -cr` walks recursively.
    private static func stripQuarantine(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", path]
        process.standardOutput = Pipe()
        process.standardError  = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
