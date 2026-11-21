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
    /// The saves, one after another: one that hangs (up to the request's timeout) and then fails would otherwise come
    /// back over a newer title that went out meanwhile.
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Counts the saves: only the newest says how it went (`unsent`, a report) and ends `saving`.
    @ObservationIgnored private var latest = 0

    /// The page's title, or the one on its way to it or waiting to go; not while one is being typed. A page that loads
    /// again while a rename is on its way (an icon set meanwhile) still has the older title: shown, a focus loss would
    /// send it over the rename.
    func show(_ page: Page, typing: Bool) {
        if !typing { text = saving ?? unsent ?? page.title ?? "" }
    }

    /// Return in the field (it takes it as a line break, being vertical) ends the title (`SingleLineInput`): a pasted
    /// title's line breaks become spaces, a stored one stays. `old`: the text before this change. Returns whether the
    /// input ends, so the field gives up focus.
    func takeReturn(after old: String) -> Bool {
        guard let taken = SingleLineInput.taking(text, after: old) else { return false }
        text = taken.text
        return taken.endsInput
    }

    /// Saves the typed title in `pageSession`, the session the page loaded in; reads its values before the task starts,
    /// so it also works from `onDisappear`. One the server doesn't get (offline, unreachable) stays on the device and
    /// goes out later (`AppSession.sendUnsentTitles`). Kept before it is sent, so it survives the app ending in the
    /// background meanwhile; it goes once sent. Sent after the titles saved before it, as typed. `sent` runs on its own
    /// once the server has it, `report` says what failed.
    @discardableResult
    func commit(_ page: Page, in pageSession: ReadySession, session: AppSession, changes: ContentChanges,
                sent: @escaping () async -> Void, report: @escaping (String) -> Void) -> Task<Void, Never>? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The loaded title goes again while a newer one is on its way or waits on the device: typed back, it must come
        // after that one, or the newer one goes out over it later.
        guard trimmed != (page.title ?? "") || saving != nil || unsent != nil, trimmed != saving else { return nil }
        // Its session ended (401) or a link switched servers: the title waits for the next sign-in there, like the text.
        guard session.isStillCurrent(pageSession) else {
            return Task { await session.keepUnsentTitle(trimmed, pageId: page.id, spaceId: page.spaceId, in: pageSession.unsentChanges) }
        }
        saving = trimmed
        latest += 1
        let id = latest
        let previous = queue
        let task = Task {
            // Replaces an older kept title, which then can't overwrite this one. At once, not after the older title's
            // request, which may take until its timeout.
            let kept = await session.keepUnsentTitle(trimmed, pageId: page.id, spaceId: page.spaceId, in: pageSession.unsentChanges)
            await previous?.value
            do {
                // With the page's session: a switch while the title was kept would take it to the other server.
                _ = try await session.send(Endpoints.Pages.update(pageId: page.id, title: trimmed), on: pageSession)
                // From the store it was kept in: a sign-out or switch meanwhile left it there, to go out again later
                // over a newer rename.
                await session.forgetUnsentTitle(pageId: page.id, title: trimmed, in: pageSession.unsentChanges)
                changes.pageChanged(in: page.spaceId)
                // Unless a newer title waits to go: the page loads again with that one.
                if id == latest {
                    unsent = nil
                    // The response lacks permissions and space info, so the page loads again instead of taking it; on
                    // its own, so a background task doesn't wait for it.
                    Task { await sent() }
                }
            } catch where UnsentChanges.isFinal(error) {
                await session.forgetUnsentTitle(pageId: page.id, title: trimmed, in: pageSession.unsentChanges)
                if id == latest { report(error.userMessage) }
            } catch where kept {
                // Only while it still waits: the app sends kept titles when the network returns, maybe while this
                // request hung, and another window's newer title replaces it.
                let waits = await session.unsentTitle(pageId: page.id, in: pageSession.unsentChanges) == trimmed
                if id == latest {
                    unsent = waits ? trimmed : nil
                    if waits { report(String(localized: "The title goes to the server once it can be reached.")) }
                }
            } catch {
                if id == latest { report(String(localized: "Title not saved: \(error.userMessage)")) }
            }
            if id == latest { saving = nil }
        }
        queue = task
        return task
    }

    /// Shows the page's kept title, and sends it right away if the server answers again. Returns whether it went out:
    /// the page then loads again, with it. `consented`: the lock the person chose to edit the page through, if any; a
    /// verified page's title waits for it (`AppSession.sendUnsentTitles`).
    func showUnsent(of page: Page?, consented: PageVerification.Lock?, typing: () -> Bool, isOffline: () -> Bool,
                    session: AppSession, changes: ContentChanges, report: (String) -> Void) async -> Bool {
        guard let page, let kept = await session.unsentTitle(pageId: page.id) else {
            unsent = nil
            return false
        }
        unsent = kept
        if !typing() { text = kept }
        guard !isOffline() else { return false }
        let sent = await session.sendUnsentTitles(consented: consented.map { [page.id: $0] } ?? [:])
        // Every kept title goes, not only this page's: one change for all their spaces, or views see only the last one.
        changes.pagesChanged(in: sent.spaces)
        if let notice = UnsentEdits.DroppedChange.notice(for: sent.dropped) { report(notice) }
        guard await session.unsentTitle(pageId: page.id) == nil else { return false }
        unsent = nil
        return true
    }
}
