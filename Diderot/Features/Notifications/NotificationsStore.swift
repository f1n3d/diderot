import Foundation
import Observation
import DocmostKit

/// Notifications and unread count. No push channel: `MainTabView` polls the count in the foreground.
@MainActor
@Observable
final class NotificationsStore {
    private(set) var unreadCount = 0
    private(set) var listState: LoadState<[ActivityNotification]> = .idle
    var filter: Endpoints.Notifications.Filter = .all
    /// "Unread only" as in the web client, filtered here (the server filters only by direct/updates). On by default
    /// and persisted; items marked read then leave the popover.
    var unreadOnly = NotificationsStore.storedUnreadOnly {
        didSet { UserDefaults.standard.set(unreadOnly, forKey: Self.unreadOnlyKey) }
    }
    /// A mark the server didn't take (the popover shows it): the notification is unread again, which used to say nothing.
    var toast: String?
    private unowned let session: AppSession

    static let pollInterval: Duration = .seconds(60)
    private static let unreadOnlyKey = "notifications.unreadOnly"

    /// `bool(forKey:)` also parses string launch arguments like `-notifications.unreadOnly NO`.
    private static var storedUnreadOnly: Bool {
        UserDefaults.standard.object(forKey: unreadOnlyKey) == nil || UserDefaults.standard.bool(forKey: unreadOnlyKey)
    }

    /// Items as the popover shows them.
    var visibleItems: [ActivityNotification]? {
        listState.value.map { items in unreadOnly ? items.filter(\.isUnread) : items }
    }

    /// Counts list loads and marks: a list the server answered before a newer load or a mark doesn't win (it showed a
    /// notification just marked as read unread again, and raised the badge).
    @ObservationIgnored private var listLoads = 0

    init(session: AppSession) {
        self.session = session
    }

    func refreshUnreadCount() async {
        if let result = try? await session.send(Endpoints.Notifications.unreadCount) {
            unreadCount = result.count
        }
    }

    func loadList() async {
        guard session.client != nil else { return }
        if listState.value == nil { listState = .loading }
        let filter = filter
        listLoads += 1
        let load = listLoads
        do {
            let page = try await session.send(Endpoints.Notifications.list(filter: filter, limit: 50))
            // Filter changed meanwhile: the load for the new one shows its list.
            guard filter == self.filter else { return }
            // A mark or a newer load came meanwhile: this answer may predate it. The list keeps the mark, and the
            // next load (a newer one, or the popover's next) brings the server's state.
            guard load == listLoads else { return }
            listState = .loaded(page.items)
            // Only a complete, unfiltered list yields the bell's count; otherwise ask the server.
            if filter == .all, page.items.count < 50 {
                unreadCount = page.items.filter(\.isUnread).count
            } else {
                await refreshUnreadCount()
            }
        } catch is CancellationError {
        } catch {
            if listState.value == nil { listState = .failed(error) }
        }
    }

    func markRead(_ notification: ActivityNotification) async {
        guard notification.isUnread, session.client != nil else { return }
        if let items = listState.value {
            listState = .loaded(items.map { $0.id == notification.id ? $0.markedRead() : $0 })
        }
        unreadCount = max(unreadCount - 1, 0)
        listLoads += 1
        do {
            _ = try await session.send(Endpoints.Notifications.markRead([notification.id]))
        } catch {
            AppLog.ui.error("Mark read failed: \(error.userMessage, privacy: .public)")
            toast = String(localized: "Not marked as read: \(error.userMessage)")
            if let items = listState.value {
                listState = .loaded(items.map { $0.id == notification.id ? notification : $0 })
            }
            unreadCount += 1
            // Offline the reload fails too and the undo stays; online it also covers marks that ran meanwhile.
            await loadList()
        }
    }

    func markAllRead() async {
        guard session.client != nil else { return }
        let before = (listState, unreadCount)
        if let items = listState.value {
            listState = .loaded(items.map { $0.markedRead() })
        }
        unreadCount = 0
        listLoads += 1
        do {
            _ = try await session.send(Endpoints.Notifications.markAllRead)
        } catch {
            AppLog.ui.error("Mark all read failed: \(error.userMessage, privacy: .public)")
            toast = String(localized: "Not marked as read: \(error.userMessage)")
            (listState, unreadCount) = before
            await loadList()
        }
    }
}

private extension ActivityNotification {
    func markedRead() -> ActivityNotification {
        guard isUnread else { return self }
        var copy = self
        copy.readAt = .now
        return copy
    }
}
