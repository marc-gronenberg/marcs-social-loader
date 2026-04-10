import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(Localization.self) private var l10n

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

    private var pasteButton: some View {
        Button(action: pasteFromClipboard) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 14, weight: .regular))
                Text(l10n.str(.pasteButton))
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: .command)
    }

    // MARK: - List

    private var listArea: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(manager.items) { item in
                    VideoItemView(item: item) {
                        manager.remove(item)
                    }
                    Divider()
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
        manager.add(url: text)
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

/// Prominent button with a red hover state (#C91429).
struct DownloadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DownloadButtonBody(configuration: configuration)
    }
}

private struct DownloadButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// Brand red used on hover. #C91429
    private let hoverColor = Color(red: 201.0/255.0, green: 20.0/255.0, blue: 41.0/255.0)

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .contentShape(Rectangle())
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
        if configuration.isPressed {
            return hoverColor.opacity(0.85)
        }
        if isHovering {
            return hoverColor
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color.secondary
        }
        if isHovering || configuration.isPressed {
            return .white
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
