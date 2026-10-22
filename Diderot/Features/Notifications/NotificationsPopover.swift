import SwiftUI
import DocmostKit

/// Popover below the home screen's bell, on iPhone too (not a sheet). Tap: marks read, closes the popover, opens
/// its page if any. Swipe left: only marks read (the server can't delete notifications); "Unread Only" then hides it.
struct NotificationsPopover: View {
    @Environment(AppSession.self) private var session
    @Environment(NotificationsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onOpen: (PageSelection) -> Void
    @State private var listHeight: CGFloat = 0

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Activity")
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("Filter", selection: $store.filter) {
                        Text("All").tag(Endpoints.Notifications.Filter.all)
                        Text("Direct").tag(Endpoints.Notifications.Filter.direct)
                        Text("Updates").tag(Endpoints.Notifications.Filter.updates)
                    }
                    Toggle("Unread Only", systemImage: "envelope.badge", isOn: $store.unreadOnly)
                    Divider()
                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                        Task { await store.markAllRead() }
                    }
                    .disabled(store.unreadCount == 0)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            Divider()
            content
        }
        .frame(width: 360)
        .task { await store.loadList() }
        .onChange(of: store.filter) { _, _ in
            Task { await store.loadList() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.listState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(40)
        case .failed(let error):
            ErrorStateView(error: error) { await store.loadList() }
                .padding(.vertical, 8)
        case .loaded:
            let items = store.visibleItems ?? []
            if items.isEmpty {
                if store.unreadOnly {
                    ContentUnavailableView("No unread notifications", systemImage: "bell", description: Text("You're all caught up."))
                        .padding(.vertical, 8)
                } else {
                    ContentUnavailableView("No notifications", systemImage: "bell", description: Text("Mentions, comments and page updates show up here."))
                        .padding(.vertical, 8)
                }
            } else {
                // `List` (not a stack) for swiping; the popover grows with it up to a maximum height, then it scrolls.
                List(items) { notification in
                    Button {
                        open(notification)
                    } label: {
                        NotificationRow(notification: notification, baseURL: session.server?.url)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .accessibilityIdentifier("notification-\(notification.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if notification.isUnread {
                            Button("Mark as Read", systemImage: "envelope.open") {
                                Task { await store.markRead(notification) }
                            }
                            .tint(.accentColor)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.default, value: items.map(\.id))
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in listHeight = height }
                .frame(height: min(max(listHeight, 72), 520))
                .refreshable { await store.loadList() }
            }
        }
    }

    private func open(_ notification: ActivityNotification) {
        Task { await store.markRead(notification) }
        if let page = notification.page {
            onOpen(PageSelection(pageId: page.id, title: page.title))
        } else {
            dismiss()
        }
    }
}

struct NotificationRow: View {
    let notification: ActivityNotification
    let baseURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: notification.actor?.name, avatarUrl: notification.actor?.avatarUrl, baseURL: baseURL)
            VStack(alignment: .leading, spacing: 3) {
                sentence
                    .lineLimit(3)
                HStack(spacing: 4) {
                    if let space = notification.space?.name {
                        Text(space)
                    }
                    if let createdAt = notification.createdAt {
                        Text("·")
                        Text(createdAt, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Row separator starts under the text, not the avatar.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if notification.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .padding(.top, 6)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// One full sentence per type, not fragments, so each localization controls word order. Types and wording follow
    /// the web's `notification-item.tsx`.
    var sentence: Text {
        let actor = Text(notification.actor?.name ?? String(localized: "Someone")).bold()
        let target = Text(notification.page?.displayTitle ?? notification.space?.name ?? String(localized: "a page")).bold()
        let destination = Text(notification.data?["destinationName"]?.stringValue ?? "").bold()
        let type = notification.type
        switch type {
        case "comment.user_mention": return Text("\(actor) mentioned you in a comment on \(target)")
        case "comment.created": return Text("\(actor) commented on \(target)")
        case "comment.resolved": return Text("\(actor) resolved a comment on \(target)")
        case "page.user_mention": return Text("\(actor) mentioned you on \(target)")
        case "page.updated": return Text("\(actor) updated \(target)")
        case "page.permission_granted": return Text("\(actor) gave you access to \(target)")
        case "page.verified": return Text("\(actor) verified \(target)")
        case "page.approval_requested": return Text("\(actor) submitted \(target) for your approval")
        case "page.approval_rejected": return Text("\(actor) returned \(target) for revision")
        // System notices: the server sends them without an actor.
        case "page.verification_expiring": return Text("Verification of \(target) expires soon")
        case "page.verification_expired": return Text("Verification of \(target) has expired")
        case "siem_destination.failing": return Text("SIEM destination \(destination) is failing")
        case "siem_destination.disabled": return Text("SIEM destination \(destination) was disabled after 24 hours of failures")
        case "siem_destination.recovered": return Text("SIEM destination \(destination) recovered")
        default:
            if type.hasPrefix("page.verification") { return Text("\(actor) changed the verification of \(target)") }
            if type.hasPrefix("page.approval") { return Text("\(actor) changed the approval of \(target)") }
            return Text("\(actor) \(type.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")) \(target)")
        }
    }
}

/// Avatar or initial.
struct AvatarView: View {
    let name: String?
    let avatarUrl: String?
    let baseURL: URL?
    var size: CGFloat = 36

    var body: some View {
        RemoteThumbnail(url: baseURL.flatMap { ImageURL.resolve(avatarUrl, kind: .avatar, baseURL: $0) }, size: size,
                        shape: Circle()) { initial }
    }

    private var initial: some View {
        Circle()
            .fill(Color.tint(for: name ?? "?").opacity(0.2))
            .frame(width: size, height: size)
            .overlay {
                Text(String((name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.tint(for: name ?? "?"))
            }
            .accessibilityHidden(true)
    }
}
