import Foundation
import DocmostKit

/// Where a page comes from (`PageView`), in the session it loads in: its saved copy, shown at once, then the server's
/// page with its breadcrumbs and space, kept for the next time; and the document model made for it. Forgets what the
/// device keeps of a page gone for good.
struct PageLoader {
    /// The id the page was opened with (`PageSelection.pageId`): its id or slug id.
    let pageId: String
    /// The session the page loads in: its requests, its saved copies, its unsent changes.
    let owner: ReadySession
    let session: AppSession

    private var cache: DiskCache { owner.cache }

    /// The saved copy, with the document its unsent changes make (`UnsentChanges`) and its breadcrumbs.
    func saved() async -> (page: Page, unsent: PMNode?, breadcrumbs: [Breadcrumb])? {
        guard let page = await cache.read(Page.self, key: CacheKey.page(pageId)) else { return nil }
        let unsent = try? await owner.unsentChanges.read(PMNode.self, key: CacheKey.unsentDocument(page.id))
        return (page, unsent, await cache.read([Breadcrumb].self, key: CacheKey.breadcrumbs(page.id)) ?? [])
    }

    /// The server's page. One deleted for good or no longer shared throws that (`APIError.isGone`), in the app's language
    /// (the server's is English).
    func fetch() async throws -> Page {
        do {
            return try await session.load(Endpoints.Pages.info(pageId: pageId), of: owner)
        } catch let error as APIError where error.isGone {
            if case .forbidden = error { throw APIError.forbidden(message: String(localized: "You no longer have access to this page.")) }
            throw APIError.notFound(message: String(localized: "This page doesn't exist anymore."))
        }
    }

    /// Saves the server's page for the next time, under its id and its slug id (links use either).
    func keep(_ page: Page) async {
        await cache.write(page, key: CacheKey.page(page.id))
        if let slugId = page.slugId, slugId != page.id {
            await cache.write(page, key: CacheKey.page(slugId))
        }
    }

    /// Forgets a page gone for good: its saved copy (`stale`, the one shown), its breadcrumbs, its level in the page
    /// tree and, for a database, its views' rows.
    func forget(_ stale: Page?) async {
        guard let stale else { return }
        for key in [stale.id, stale.slugId].compactMap({ $0 }) {
            await cache.remove(key: CacheKey.page(key))
        }
        await cache.remove(key: CacheKey.breadcrumbs(stale.id))
        if let spaceId = stale.spaceId {
            await cache.remove(key: CacheKey.tree(spaceId: spaceId, parentPageId: stale.id))
        }
        if let base = await cache.read(Base.self, key: CacheKey.base(stale.id)) {
            for view in base.views { await cache.remove(key: CacheKey.baseView(stale.id, viewId: view.id)) }
            await cache.remove(key: CacheKey.base(stale.id))
        }
    }

    /// The page's breadcrumbs from the server, saved for the next time under `page`'s id; nil if they didn't come.
    func breadcrumbs(of page: Page?) async -> [Breadcrumb]? {
        guard let crumbs = try? await session.load(Endpoints.Pages.breadcrumbs(pageId: pageId), of: owner) else { return nil }
        if let id = page?.id { await cache.write(crumbs, key: CacheKey.breadcrumbs(id)) }
        return crumbs
    }

    /// The page's space, whose settings say whether readers may comment; nil if it didn't come.
    func space(of page: Page?) async -> Space? {
        guard let spaceId = page?.spaceId else { return nil }
        return try? await session.load(Endpoints.Spaces.info(spaceId: spaceId), of: owner)
    }

    /// The page's document model: editable with an engine, or read-only with the reason; nil for a database page, whose
    /// content is rows. `unsent`: the document with changes the server doesn't have yet, shown offline and until the
    /// engine's first sync (which sends them), not where they can't go. A page left open in the engine shortly before
    /// (`LiveDocuments`) starts from that document.
    func model(for page: Page, unsent: PMNode?, isOffline: Bool, notices: AppNotices, changes: ContentChanges) -> DocumentModel? {
        if page.isBase == true { return nil }
        let reason: DocumentModel.ReadOnlyReason? = page.isInTrash ? .trash : !page.canEdit ? .noPermission : isOffline ? .offline
            : owner.newerServerVersion.map { .newerServer($0) }
        let liveOwner = LiveDocuments.Owner(owner)
        let live = LiveDocuments.document(for: page.id, owner: liveOwner, newerThan: page.updatedAt, serverClockOffset: owner.client.serverClockOffset)
        let engine = reason == nil ? WebDocumentEngine(session: session) : nil
        return DocumentModel(page: page, initialDocument: live ?? (reason == nil || reason == .offline ? unsent : nil), engine: engine,
                             readOnlyReason: reason, dependencies: dependencies(of: page, liveOwner: liveOwner, notices: notices, changes: changes))
    }

    /// What the page's model needs from the session it loaded in. Its requests are that session's: once a switch (a link
    /// to another server) has replaced it, nothing goes out, as another server would get them.
    func dependencies(of page: Page, liveOwner: LiveDocuments.Owner?, notices: AppNotices, changes: ContentChanges) -> DocumentModel.Dependencies {
        let session = session, owner = owner
        var dependencies = DocumentModel.Dependencies(
            serverURL: owner.server.url, currentUserId: owner.currentUser.user.id, liveOwner: liveOwner,
            linkPreviews: session.linkPreviews, canCreateBases: owner.entitlements.has("bases"),
            hasDocmost097Features: owner.hasDocmost097Features
        )
        dependencies.postAppNotice = { message in notices.post(message) }
        dependencies.suggest = { query in
            try await session.load(Endpoints.Search.suggest(query: query, users: true, pages: true, spaceId: page.spaceId, limit: 8), of: owner)
        }
        dependencies.lookUpPage = { slugId in try? await session.load(Endpoints.Pages.info(pageId: slugId), of: owner) }
        dependencies.createBase = { template in
            let base = try await session.send(Endpoints.Bases.create(parentPageId: page.id, template: template), on: owner)
            changes.pageChanged(in: page.spaceId)
            return base.id
        }
        dependencies.sendUpload = { file in
            try await session.perform(on: owner) { client in
                try await client.uploadAttachment(pageId: page.id, fileName: file.fileName, mimeType: file.mimeType, fileURL: file.fileURL)
            }
        }
        return dependencies
    }
}
