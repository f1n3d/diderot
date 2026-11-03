import Foundation
import DocmostKit

/// What the page's header and menu change on its server (`PageView`), in the session the page loaded in: once a switch
/// or sign-out has replaced it, nothing goes out (`SwitchedServer`), as another server would get it. Each marks the
/// page's space as changed.
struct PageEdits {
    let page: Page
    /// The session the page loaded in.
    let owner: ReadySession
    let session: AppSession
    let changes: ContentChanges

    /// A new subpage without a title, to open with its title field focused; nil for a page outside a space.
    func createSubpage() async throws -> PageSelection? {
        guard let spaceId = page.spaceId else { return nil }
        let created = try await session.send(Endpoints.Pages.create(spaceId: spaceId, parentPageId: page.id, title: nil), on: owner)
        changes.pageChanged(in: spaceId)
        var next = PageSelection(page: created)
        next.focusTitle = true
        return next
    }

    /// The page and its subpages to the trash.
    func moveToTrash() async throws {
        _ = try await session.send(Endpoints.Pages.delete(pageId: page.id), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    func restore() async throws {
        _ = try await session.send(Endpoints.Pages.restore(pageId: page.id), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    /// `nil` removes the icon.
    func setIcon(_ emoji: String?) async throws {
        _ = try await session.send(Endpoints.Pages.update(pageId: page.id, icon: emoji ?? ""), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    /// Turns the empty page into a database, as the web's "Get started with" does (`template` "kanban" or `nil`).
    func convertToDatabase(template: String?) async throws {
        _ = try await session.send(Endpoints.Bases.convert(pageId: page.id, template: template), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    /// The page as the server writes it in `format` ("markdown", "html"). Once a switch has replaced the page's session,
    /// it ends without a word, as a closing screen's request does (`CancellationError`).
    func content(as format: String) async throws -> String {
        try await session.load(Endpoints.Pages.info(pageId: page.id, format: format), of: owner).content?.stringValue ?? ""
    }
}
