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

    /// Runs `yt-dlp --dump-json --no-playlist <url>` in the background
    /// and returns the parsed, slimmed-down Info.
    static func fetch(url: String) async throws -> Info {
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
}

/// Locates CLI tools, preferring binaries bundled inside the app.
///
/// Priority order:
///   1. `Contents/Resources/bin/<name>` — shipped with the .app so users
///      don't need Homebrew.
///   2. Homebrew / system paths — fallback for development (`swift run`)
///      and for users who prefer their own installation.
enum ToolLocator {
    private static let systemSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    static func ytDlp() -> String { find("yt-dlp") }
    static func ffmpeg() -> String { find("ffmpeg") }

    /// Directory containing the bundled binaries, or nil if we're not
    /// running from a proper .app bundle (e.g. during `swift run`).
    static var bundledBinDir: String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL.appendingPathComponent("bin", isDirectory: true).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return dir
    }

    private static func find(_ name: String) -> String {
        if let binDir = bundledBinDir {
            let bundled = (binDir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        for p in systemSearchPaths {
            let full = (p as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return ""
    }
}
