import Foundation
import DocmostKit

/// The page's title as typed in its header (`PageView`), and a title the server didn't get yet (`UnsentTitle`), shown
/// with a note until it goes out.
@MainActor
@Observable
final class PageTitleEdit {
    /// The title field's text.
    var text = ""
    /// A title the server didn't get yet.
    private(set) var unsent: String?
    /// Title whose save is running: a focus loss right after leaving the page would send it a second time.
    private var saving: String?

    /// The page's title, or the one it waits to get; not while one is being typed.
    func show(_ page: Page, typing: Bool) {
        if !typing { text = unsent ?? page.title ?? "" }
    }

    /// Return in the field (it takes it as a line break, being vertical) ends the title: the break becomes a space.
    /// Returns whether it did, so the field gives up focus.
    func takeReturn() -> Bool {
        guard text.contains("\n") else { return false }
        text = text.replacingOccurrences(of: "\n", with: " ")
        return true
    }

    /// Saves the typed title in `pageSession`, the session the page loaded in; reads its values before the task starts,
    /// so it also works from `onDisappear`. One the server doesn't get (offline, unreachable) stays on the device and
    /// goes out later (`AppSession.sendUnsentTitles`). Kept before it is sent, so it survives the app ending in the
    /// background meanwhile; it goes once sent. `sent` runs on its own once the server has it, `report` says what failed.
    @discardableResult
    func commit(_ page: Page, in pageSession: ReadySession, session: AppSession, changes: ContentChanges,
                sent: @escaping () async -> Void, report: @escaping (String) -> Void) -> Task<Void, Never>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (page.title ?? ""), trimmed != saving else { return nil }
        // Its session ended (401) or a link switched servers: the title waits for the next sign-in there, like the text.
        guard session.isStillCurrent(pageSession) else {
            return Task { await session.keepUnsentTitle(trimmed, pageId: page.id, spaceId: page.spaceId, in: pageSession.unsentChanges) }
        }
        saving = trimmed
        return Task {
            // Replaces an older kept title, which then can't overwrite this one.
            let kept = await session.keepUnsentTitle(trimmed, pageId: page.id, spaceId: page.spaceId, in: pageSession.unsentChanges)
            do {
                // With the page's session: a switch while the title was kept would take it to the other server.
                _ = try await session.send(Endpoints.Pages.update(pageId: page.id, title: trimmed), on: pageSession)
                await session.forgetUnsentTitle(pageId: page.id, title: trimmed)
                unsent = nil
                changes.pageChanged(in: page.spaceId)
                // The response lacks permissions and space info, so the page loads again instead of taking it; on its
                // own, so a background task doesn't wait for it.
                Task { await sent() }
            } catch where UnsentChanges.isFinal(error) {
                await session.forgetUnsentTitle(pageId: page.id, title: trimmed)
                report(error.userMessage)
            } catch where kept {
                unsent = trimmed
                report(String(localized: "The title goes to the server once it can be reached."))
            } catch {
                report(String(localized: "Title not saved: \(error.userMessage)"))
            }
            saving = nil
        }
    }

    /// Shows the page's kept title, and sends it right away if the server answers again. Returns whether it went out:
    /// the page then loads again, with it.
    func showUnsent(of page: Page?, typing: () -> Bool, isOffline: () -> Bool, session: AppSession, changes: ContentChanges,
                    report: (String) -> Void) async -> Bool {
        guard let page, let kept = await session.unsentTitle(pageId: page.id) else {
            unsent = nil
            return false
        }
        unsent = kept
        if !typing() { text = kept }
        guard !isOffline() else { return false }
        let sent = await session.sendUnsentTitles()
        for spaceId in sent.spaces { changes.pageChanged(in: spaceId) }
        if let notice = UnsentEdits.DroppedChange.notice(for: sent.dropped) { report(notice) }
        guard await session.unsentTitle(pageId: page.id) == nil else { return false }
        unsent = nil
        return true
    }
}
