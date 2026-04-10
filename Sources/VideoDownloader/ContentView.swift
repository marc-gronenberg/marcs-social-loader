import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(Localization.self) private var l10n

    /// Hover state for the top paste button.
    @State private var isPasteHovered = false

    /// URL currently sitting in the system clipboard, if it looks like a
    /// supported video URL and isn't already in the queue. Refreshed
    /// whenever the app becomes active so the paste button can preview
    /// the host ("youtube.com", "tiktok.com") right on its label —
    /// the user knows they're one click away from queueing it.
    @State private var clipboardURL: String?

    /// Holds a URL that could reasonably mean "just this video" OR "the
    /// whole playlist" — typically YouTube's `watch?v=X&list=Y`. When
    /// non-nil, the confirmation dialog shows and asks the user which
    /// one they want. The choice then calls `manager.add(url:mode:)`
    /// with the appropriate override.
    @State private var ambiguousURL: String?

    var body: some View {
        @Bindable var mgr = manager
        ZStack {
            if manager.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    pasteButton
                        .padding(.horizontal, 14)
                        .padding(.top, 22)  // just enough to clear traffic lights
                        .padding(.bottom, 6)

                    listArea
                        .padding(.horizontal, 14)

                    bottomBar
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { refreshClipboardURL() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboardURL()
        }
        .confirmationDialog(
            "Video oder Playlist laden?",
            isPresented: Binding(
                get: { ambiguousURL != nil },
                set: { newValue in
                    if !newValue {
                        // Dialog dismissed (e.g. ESC). Cancel any
                        // background prefetch so we don't keep a
                        // rogue yt-dlp running for work the user
                        // told us not to do.
                        if let url = ambiguousURL {
                            manager.cancelPrefetch(url: url)
                        }
                        ambiguousURL = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Nur dieses Video") {
                if let url = ambiguousURL {
                    manager.cancelPrefetch(url: url)
                    manager.add(url: url, mode: .videoOnly)
                }
                ambiguousURL = nil
            }
            Button("Ganze Playlist") {
                if let url = ambiguousURL {
                    manager.add(url: url, mode: .playlist)
                }
                ambiguousURL = nil
            }
            Button("Abbrechen", role: .cancel) {
                if let url = ambiguousURL {
                    manager.cancelPrefetch(url: url)
                }
                ambiguousURL = nil
            }
        } message: {
            Text("Die URL enthält sowohl ein Video als auch eine Playlist.")
        }
    }

    // MARK: - Empty state (centered paste action)

    private var emptyState: some View {
        Button(action: pasteFromClipboard) {
            VStack(spacing: 14) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)

                Text(l10n.str(.emptyHeading))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(l10n.str(.emptyBody))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 380)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: .command)
    }

    // MARK: - Paste button (top)

    /// Shows a host-preview label ("URL einfügen — youtube.com") when a
    /// supported URL is sitting in the clipboard. Acts as a subtle hint
    /// that a single click will queue it. Falls back to the plain label
    /// when the clipboard is empty or holds something unrelated.
    private var pasteButtonLabel: String {
        if let url = clipboardURL, let host = hostName(of: url) {
            return "\(l10n.str(.pasteButton)) — \(host)"
        }
        return l10n.str(.pasteButton)
    }

    /// True when the clipboard holds a URL we can queue right now. Used
    /// to show the red-highlight variant of the button even when the
    /// user isn't hovering.
    private var hasClipboardURL: Bool { clipboardURL != nil }

    /// Combined "active" state: hover OR a fresh URL is waiting. Drives
    /// the button's tint so the hint is visible at a glance.
    private var isPasteButtonActive: Bool { isPasteHovered || hasClipboardURL }

    private var pasteButton: some View {
        Button(action: pasteFromClipboard) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .regular))
                Text(pasteButtonLabel)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isPasteButtonActive ? BrandColor.redSwiftUI : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isPasteButtonActive
                          ? BrandColor.redSwiftUI.opacity(0.08)
                          : Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isPasteButtonActive
                                    ? BrandColor.redSwiftUI
                                    : Color(nsColor: .separatorColor),
                                    lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: .command)
        .onHover { hovering in
            isPasteHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPasteButtonActive)
    }

    // MARK: - List

    private var listArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(manager.sections) { section in
                    switch section {
                    case .standalone(let item):
                        VideoItemView(item: item) {
                            manager.remove(item)
                        }
                        Divider()
                    case .group(let group, let groupItems):
                        PlaylistGroupView(
                            group: group,
                            items: groupItems,
                            onRemoveAll: { manager.removeGroup(group.id) },
                            onSetQualityAll: { quality in
                                manager.setGroupQuality(group.id, quality: quality)
                            },
                            onRemoveItem: { manager.remove($0) }
                        )
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(l10n.str(.saveLocation))
                    .font(.system(size: 12))
                Text(manager.outputDir)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(l10n.str(.changeButton)) { chooseOutputDir() }
            }

            Button(action: { manager.startDownload() }) {
                Text(downloadButtonText)
            }
            .buttonStyle(DownloadButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        !manager.isBatchRunning && manager.items.contains {
            if case .ready = $0.state { return true } else { return false }
        }
    }

    private var downloadButtonText: String {
        let readyCount = manager.items.filter {
            if case .ready = $0.state { return true } else { return false }
        }.count
        if manager.isBatchRunning { return l10n.str(.downloadButtonBusy) }
        if readyCount == 0 { return l10n.str(.downloadButtonIdle) }
        if readyCount == 1 { return l10n.str(.downloadButtonSingle, readyCount) }
        return l10n.str(.downloadButtonMany, readyCount)
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        enqueue(text)
        // Clear the hint after a successful paste so the button reverts
        // to its calm state — reappears only if the clipboard changes.
        clipboardURL = nil
    }

    /// Hands a URL off to the download manager, first routing through a
    /// confirmation dialog if the URL is ambiguous (contains both a
    /// watch target and a playlist context). Non-ambiguous URLs go
    /// straight to `manager.add(url:)`.
    ///
    /// For ambiguous URLs, we also kick off a background playlist
    /// prefetch *before* showing the dialog. While the user is reading
    /// the dialog and deciding which option to click, yt-dlp is
    /// already enumerating the playlist in the background. By the
    /// time they pick "Ganze Playlist", the list is usually ready to
    /// drop straight into the queue — no extra wait after the click.
    private func enqueue(_ url: String) {
        if DownloadManager.urlIsAmbiguousPlaylist(url) {
            manager.prefetchPlaylist(url: url)
            ambiguousURL = url
        } else {
            manager.add(url: url)
        }
    }

    /// Called on app activation and on first appear. Reads the clipboard,
    /// decides whether it holds a *new* supported URL (not already in
    /// the queue) and updates `clipboardURL` accordingly.
    ///
    /// Side effect beyond the visual hint: also kicks off a background
    /// metadata prefetch for the detected URL so yt-dlp runs in
    /// parallel with whatever the user is doing between copying the URL
    /// and clicking paste. By the time they click, the title, thumbnail
    /// and height list are usually already in the cache and the item
    /// drops into the queue fully populated within ~50 ms.
    ///
    /// When the clipboard URL changes from one value to another, the
    /// stale prefetch is cancelled so we don't leave rogue yt-dlp
    /// processes running for URLs the user no longer cares about.
    ///
    /// Read-only — the clipboard itself is never modified. The user is
    /// always in control; this only changes how the button *looks*
    /// and what metadata is pre-warmed in the background.
    private func refreshClipboardURL() {
        let previousURL = clipboardURL

        // Resolve what the clipboard currently holds, if anything.
        let newURL: String? = {
            guard let raw = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  raw.hasPrefix("http://") || raw.hasPrefix("https://"),
                  URL(string: raw) != nil
            else {
                return nil
            }
            // Don't hint at URLs the user already queued.
            if manager.items.contains(where: { $0.url == raw }) {
                return nil
            }
            return raw
        }()

        // Nothing changed — skip the cancel/prefetch dance entirely.
        guard newURL != previousURL else { return }

        // Cancel any stale prefetch so a yt-dlp for the previous URL
        // doesn't keep running when the user already moved on.
        if let previous = previousURL {
            manager.cancelPrefetch(url: previous)
        }

        clipboardURL = newURL

        // Kick off a fresh prefetch for the new URL — dispatches to
        // playlist or single-video path inside the manager.
        if let url = newURL {
            manager.prefetchURL(url)
        }
    }

    /// Extracts a human-readable host label from a URL string, e.g.
    /// "youtube.com" or "tiktok.com". Drops the `www.` prefix. Returns
    /// nil for anything that doesn't parse.
    private func hostName(of urlString: String) -> String? {
        guard let url = URL(string: urlString), var host = url.host else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.isEmpty ? nil : host
    }

    private func chooseOutputDir() {
        // Defer out of the current SwiftUI click cycle so the button's
        // release animation fully completes before AppKit takes over.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = l10n.str(.pickerPrompt)
            panel.title = l10n.str(.pickerTitle)
            panel.message = l10n.str(.pickerMessage)
            panel.directoryURL = URL(fileURLWithPath: manager.outputDir)

            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                manager.outputDir = url.path
                var cfg = AppConfig.load()
                cfg.outputDir = url.path
                cfg.save()
            }

            // Prefer presenting as a sheet attached to the main window —
            // different animation than runModal() and the macOS-idiomatic
            // pattern when you have a document-style main window.
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}

// MARK: - Download button style

/// Prominent button with the brand-red hover state from BrandColor.
struct DownloadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DownloadButtonBody(configuration: configuration)
    }
}

private struct DownloadButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// Brand red used on hover — sampled from the app icon.
    private var hoverColor: Color { BrandColor.redSwiftUI }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hovering in
                guard isEnabled else {
                    isHovering = false
                    return
                }
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color(nsColor: .quaternarySystemFill)
        }
        if isHovering || configuration.isPressed {
            return hoverColor.opacity(0.08)
        }
        return Color(nsColor: .textBackgroundColor)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color.secondary
        }
        if isHovering || configuration.isPressed {
            return hoverColor
        }
        return Color.primary
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.clear
        }
        if isHovering || configuration.isPressed {
            return hoverColor
        }
        return Color(nsColor: .separatorColor)
    }
}
