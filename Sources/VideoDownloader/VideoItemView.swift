import SwiftUI
import AppKit

/// One card in the queue list.
struct VideoItemView: View {
    @Bindable var item: VideoItem
    let onRemove: () -> Void

    @Environment(Localization.self) private var l10n

    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldFocused: Bool
    /// NSEvent monitor that detects clicks outside the text field while editing.
    @State private var clickOutsideMonitor: Any?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Thumbnail
            thumbnail
                .frame(width: 96, height: 54)
                .background(Color(nsColor: .quaternarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Text + controls
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    titleView
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isBusy ? l10n.str(.tooltipCancelDownload) : l10n.str(.tooltipRemove))
                }

                HStack(spacing: 10) {
                    Text(item.durationText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if case .ready = item.state {
                        qualityPicker
                    } else if case .loading = item.state {
                        ProgressView()
                            .controlSize(.small)
                        Text(l10n.str(.loadingInfo)).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if case .error(let msg) = item.state {
                        Text("✗ \(msg)")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        qualityPicker.disabled(true)
                    }

                    Spacer(minLength: 0)

                    if !item.statusLine.isEmpty, showsStatusLine {
                        Text(item.statusLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if showsProgressBar {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: Subviews

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Titel", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .focused($titleFieldFocused)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 1)
                        )
                )
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused && isEditingTitle {
                        commitTitleEdit()
                    }
                }
        } else {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).onEnded {
                        guard !isBusy else { return }
                        beginTitleEdit()
                    }
                )
                .help(l10n.str(.tooltipRename))
        }
    }

    private func beginTitleEdit() {
        editedTitle = item.title
        isEditingTitle = true
        DispatchQueue.main.async {
            titleFieldFocused = true
        }
        installClickOutsideMonitor()
    }

    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty → clear the override and fall back to the original title
        if trimmed.isEmpty {
            item.customTitle = nil
        } else if trimmed != (item.info?.title ?? item.url) {
            item.customTitle = trimmed
        } else {
            // User typed exactly the original title → clear override
            item.customTitle = nil
        }
        isEditingTitle = false
        removeClickOutsideMonitor()
    }

    private func cancelTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        removeClickOutsideMonitor()
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Only react while we're actually editing.
            guard isEditingTitle else { return event }
            // If the click landed inside an NSTextView (i.e. our own text
            // field's field editor), let it through without committing —
            // the user is just placing the cursor.
            if let window = event.window,
               let hit = window.contentView?.hitTest(event.locationInWindow) {
                var view: NSView? = hit
                while let current = view {
                    if current is NSTextView { return event }
                    view = current.superview
                }
            }
            // Click is outside the text field → commit on the next runloop
            // tick so the mouseDown event itself completes cleanly first.
            DispatchQueue.main.async {
                commitTitleEdit()
            }
            return event
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = item.info?.thumbnail {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(nsColor: .quaternarySystemFill)
                }
            }
        } else {
            Color(nsColor: .quaternarySystemFill)
        }
    }

    private var qualityPicker: some View {
        Picker("", selection: $item.selectedQuality) {
            ForEach(localizedQualityOptions, id: \.key) { opt in
                Text(opt.label).tag(opt.key)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
    }

    /// Like `item.qualityOptions`, but with the "Best" and "Audio (MP3)"
    /// labels translated into the current UI language.
    private var localizedQualityOptions: [(key: String, label: String)] {
        var opts: [(String, String)] = [("best", l10n.str(.qualityBest))]
        for h in item.info?.heights ?? [] {
            opts.append(("\(h)p", "\(h)p"))
        }
        opts.append(("audio_mp3", l10n.str(.qualityAudioMP3)))
        return opts
    }

    // MARK: State helpers

    private var isBusy: Bool {
        switch item.state {
        case .downloading, .postprocessing: return true
        default: return false
        }
    }

    private var showsProgressBar: Bool {
        switch item.state {
        case .downloading, .postprocessing: return true
        default: return false
        }
    }

    private var showsStatusLine: Bool {
        switch item.state {
        case .downloading, .postprocessing, .done, .error: return true
        default: return false
        }
    }
}
