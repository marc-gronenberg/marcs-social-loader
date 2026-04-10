import Foundation

/// Turns yt-dlp stderr output into something a human can read, and
/// decides whether a failed run is worth retrying.
///
/// yt-dlp's error messages are deliberately technical and very consistent
/// — every terminal condition has a stable prefix we can pattern-match
/// on. We don't translate every possible failure, just the ones users
/// actually hit on a daily basis: private videos, region locks, age gates,
/// logins, removed content, and transient network blips.
enum ErrorMapper {

    /// Returns true if the failure is YouTube's "sign in to confirm
    /// you're not a bot" gate. This check fires periodically on fresh
    /// IPs or after too many requests, and the standard workaround
    /// is to retry with an alternative `player_client` (tv_embedded
    /// usually bypasses it). Callers use this signal to switch
    /// `--extractor-args` on the retry instead of giving up.
    static func isYouTubeBotCheck(stderr: String) -> Bool {
        let s = stderr.lowercased()
        // yt-dlp's message is pretty stable but slightly varied
        // across versions. Match on the distinctive phrase.
        return s.contains("sign in to confirm you're not a bot")
            || s.contains("sign in to confirm you are not a bot")
            || s.contains("confirm you're not a bot")
    }

    /// Returns true if the failure looks like a transient network issue
    /// worth retrying automatically. Anything that's permanently broken
    /// (private, removed, geo-blocked, login required, …) returns false
    /// so we don't waste the user's time.
    static func isTransient(stderr: String) -> Bool {
        let s = stderr.lowercased()

        // Anything on this list means "don't retry, this will never work".
        let terminalMarkers: [String] = [
            "private video",
            "video unavailable",
            "this video has been removed",
            "this video is not available",
            "sign in to confirm",
            "login required",
            "members-only",
            "members only",
            "premieres in",
            "this live event",
            "unsupported url",
            "not a valid url",
            "is not a valid url",
            "no video formats found",
            "requested format is not available",
            "account associated with this video has been terminated",
            "this channel is not available",
            "this video is only available to music premium",
            "playback on other websites has been disabled",
        ]
        for marker in terminalMarkers {
            if s.contains(marker) { return false }
        }

        // YouTube's bot-check gate counts as transient — we have a
        // specific workaround (alternative player_client) that the
        // retry loop applies on the next attempt.
        if isYouTubeBotCheck(stderr: stderr) { return true }

        // Anything on this list is worth another shot.
        let transientMarkers: [String] = [
            "http error 429",
            "too many requests",
            "http error 500",
            "http error 502",
            "http error 503",
            "http error 504",
            "connection reset",
            "connection timed out",
            "connection refused",
            "network is unreachable",
            "temporary failure",
            "unable to download webpage",
            "unable to extract",
            "fragment",     // fragment N of M failed after retries
            "read timed out",
            "timed out",
            "incomplete read",
        ]
        for marker in transientMarkers {
            if s.contains(marker) { return true }
        }

        // Default: assume it's not transient. We'd rather surface a
        // message to the user quickly than spin on an unknown error.
        return false
    }

    /// Turns a raw yt-dlp stderr dump into a short, actionable message.
    /// Falls back to the first meaningful stderr line if nothing matches.
    static func friendlyMessage(stderr: String, exitCode: Int32) -> String {
        let s = stderr.lowercased()

        // Most specific first — some markers overlap.
        if s.contains("private video") || s.contains("is private") {
            return "Dieses Video ist privat."
        }
        if s.contains("this video has been removed") || s.contains("has been removed by") {
            return "Das Video wurde entfernt."
        }
        if s.contains("account associated with this video has been terminated")
            || s.contains("this channel is not available") {
            return "Der Kanal ist nicht mehr verfügbar."
        }
        if s.contains("video unavailable") || s.contains("this video is not available") {
            return "Video nicht verfügbar (evtl. Region-Sperre)."
        }
        if s.contains("sign in to confirm") && s.contains("age") {
            return "Altersbeschränkung — Login nötig, wird nicht unterstützt."
        }
        if s.contains("sign in") || s.contains("login required") {
            return "Login erforderlich — wird nicht unterstützt."
        }
        if s.contains("members-only") || s.contains("members only") {
            return "Nur für Mitglieder verfügbar."
        }
        if s.contains("this video is only available to music premium") {
            return "Nur für Music-Premium-Nutzer verfügbar."
        }
        if s.contains("this live event") || s.contains("premieres in") {
            return "Live-Stream oder geplante Premiere — noch nicht ladbar."
        }
        if s.contains("unsupported url") || s.contains("is not a valid url") {
            return "URL wird nicht unterstützt."
        }
        if s.contains("no video formats found") || s.contains("requested format is not available") {
            return "Keine ladbare Videospur gefunden."
        }
        if s.contains("playback on other websites has been disabled") {
            return "Einbettung gesperrt — dieses Video kann nicht geladen werden."
        }
        if isYouTubeBotCheck(stderr: stderr) {
            return "YouTube fordert gerade einen Bot-Check. In ein paar Minuten erneut versuchen."
        }
        if s.contains("http error 429") || s.contains("too many requests") {
            return "Zu viele Anfragen — die Plattform drosselt gerade. Später erneut versuchen."
        }
        if s.contains("http error 403") || s.contains("forbidden") {
            return "Zugriff verweigert (403) — evtl. Region-Sperre oder Login nötig."
        }
        if s.contains("http error 404") || s.contains("not found") {
            return "Video nicht gefunden (404)."
        }
        if s.contains("http error 5") {
            return "Server der Plattform antwortet gerade nicht. Später erneut versuchen."
        }
        if s.contains("connection") && (s.contains("timed out") || s.contains("reset") || s.contains("refused")) {
            return "Netzwerkfehler — Verbindung zur Plattform fehlgeschlagen."
        }
        if s.contains("ssl") || s.contains("certificate") {
            return "SSL-Fehler — Verbindung zur Plattform fehlgeschlagen."
        }

        // Last resort: return the first meaningful stderr line, trimmed
        // of yt-dlp's "ERROR: " prefix if present. Falls back to a
        // generic message if stderr is empty.
        let lines = stderr.split(whereSeparator: \.isNewline)
        for raw in lines {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("ERROR:") {
                line = String(line.dropFirst("ERROR:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("WARNING:") { continue }
            // Skip yt-dlp's URL echo on the first line.
            if line.hasPrefix("[") && line.contains("]") && !line.lowercased().contains("error") {
                continue
            }
            return line.isEmpty ? "Fehler (Code \(exitCode))" : line
        }
        return "Fehler (Code \(exitCode))"
    }
}
