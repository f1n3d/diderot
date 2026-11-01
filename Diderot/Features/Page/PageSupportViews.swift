import SwiftUI
import DocmostKit

struct BreadcrumbsView: View {
    let crumbs: [Breadcrumb]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.dropLast().enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 3) {
                        if let icon = crumb.icon, !icon.isEmpty {
                            Text(icon)
                        }
                        Text(crumb.displayTitle)
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TrashBanner: View {
    let page: Page

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("This page is in the trash.")
                    .font(.subheadline.weight(.semibold))
                if let by = page.deletedBy?.name, let at = page.deletedAt {
                    Text("Deleted by \(by) \(at, format: .relative(presentation: .named))")
                        .font(.caption)
                }
            }
        } icon: {
            Image(systemName: "trash")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The editor's message (a change it couldn't apply, why the page is read-only) at the top edge, where it stays in sight:
/// below the last block, someone editing near the top of a long page never saw it. VoiceOver reads it out.
struct EditorMessageBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .task(id: message) { AccessibilityNotification.Announcement(message).post() }
    }
}

/// Live-editing status in the toolbar: saved, saving, connecting, offline, read-only. "Saved" once the server confirmed
/// every change; it used to show as soon as the engine synced, also while changes went into a connection that had died
/// without notice, for the 30 s until the engine noticed.
struct StatusPill: View {
    let status: EngineStatus
    let readOnlyReason: DocumentModel.ReadOnlyReason?
    /// The server hasn't confirmed every change.
    let unconfirmed: Bool
    /// Symbol only (narrow toolbar, e.g. iPhone portrait next to the comment button); the text remains for VoiceOver.
    var compact = false
    /// Unconfirmed for longer than `savingDelay`: every change counts until the server confirms it a moment later, and
    /// the pill would flicker with each one while someone types.
    @State private var saving = false

    static let savingDelay: Duration = .seconds(2)

    private var content: (symbol: String, text: LocalizedStringKey, tint: Color) {
        if let readOnlyReason {
            switch readOnlyReason {
            case .offline: return ("wifi.slash", "Offline", .orange)
            case .notConnected: return ("icloud.slash", "Not connected", .orange)
            case .trash: return ("trash", "In Trash", .secondary)
            case .noPermission, .newerServer: return ("lock", "Read only", .secondary)
            }
        }
        switch status {
        case .synced where saving: return ("icloud.and.arrow.up", "Saving", .secondary)
        case .synced: return ("checkmark.icloud", "Saved", .green)
        case .idle, .loading, .connecting, .connected: return ("arrow.triangle.2.circlepath.icloud", "Connecting", .secondary)
        case .disconnected, .failed: return ("icloud.slash", "Offline", .orange)
        }
    }

    var body: some View {
        let item = content
        HStack(spacing: 4) {
            Image(systemName: item.symbol)
            if !compact { Text(item.text) }
        }
        // The toolbar would cut the text short ("Sav…") rather than make room.
        .fixedSize()
        .font(.caption.weight(.medium))
        .foregroundStyle(item.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.text))
        .accessibilityIdentifier("page-status")
        .task(id: unconfirmed) {
            guard unconfirmed else {
                saving = false
                return
            }
            try? await Task.sleep(for: Self.savingDelay)
            if !Task.isCancelled { saving = true }
        }
    }
}

/// Small chip (space, date, …).
struct Chip: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }
}
