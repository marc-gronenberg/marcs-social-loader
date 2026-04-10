import SwiftUI
import AppKit

/// Collapsible container that renders every queue row belonging to
/// the same playlist under a single header. The header carries the
/// playlist title, the item count, a group-wide quality picker
/// (applies the selected quality to every child on change), and an
/// X button that removes the whole group in one click.
///
/// Individual child rows retain their own X button, quality picker,
/// and double-click-to-rename behavior — this view does not limit
/// per-item control, it just adds bulk actions on top.
struct PlaylistGroupView: View {
    let group: PlaylistGroup
    let items: [VideoItem]
    let onRemoveAll: () -> Void
    let onSetQualityAll: (String) -> Void
    let onRemoveItem: (VideoItem) -> Void

    @Environment(Localization.self) private var l10n

    /// Expand/collapse state is per-instance and lives in the view
    /// so it survives item additions/removals within the same group.
    @State private var isExpanded: Bool = true
    @State private var groupQuality: String = "best"
    @State private var isHeaderHovered = false
    @State private var isXHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                ForEach(items) { item in
                    VideoItemView(item: item) {
                        onRemoveItem(item)
                    }
                    // Indent children slightly so the visual
                    // hierarchy reads without having to count rows.
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(BrandColor.redSwiftUI.opacity(0.35))
                            .frame(width: 2)
                            .padding(.vertical, 4)
                    }
                    Divider()
                        .padding(.leading, 10)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Disclosure chevron
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Playlist icon
            Image(systemName: "text.badge.plus")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)

            // Title + count
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(countLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Group-wide quality picker
            Picker("", selection: $groupQuality) {
                Text(l10n.str(.qualityBest)).tag("best")
                Text("2160p").tag("2160p")
                Text("1440p").tag("1440p")
                Text("1080p").tag("1080p")
                Text("720p").tag("720p")
                Text("480p").tag("480p")
                Text("360p").tag("360p")
                Text(l10n.str(.qualityAudioMP3)).tag("audio_mp3")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: groupQuality) { _, new in
                onSetQualityAll(new)
            }

            // Remove-all X button
            Button(action: onRemoveAll) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isXHovered ? Color.primary : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Gesamte Playlist entfernen")
            .onHover { hovering in
                isXHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHeaderHovered
                      ? Color(nsColor: .quaternarySystemFill).opacity(0.6)
                      : Color(nsColor: .quaternarySystemFill).opacity(0.3))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Click anywhere on the header (outside the controls)
            // toggles expand/collapse — matches the Finder / Music
            // app disclosure behaviour.
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        }
        .onHover { hovering in
            isHeaderHovered = hovering
        }
    }

    // MARK: - Helpers

    private var countLabel: String {
        items.count == 1 ? "1 Video" : "\(items.count) Videos"
    }
}
