import Foundation
import Observation
import DocmostKit

/// A page's comments, shared by the toolbar button (count) and the sheet. Changes reload the list: the server supplies
/// names and timestamps.
@MainActor
@Observable
final class PageComments {
    let pageId: String
    private(set) var state: LoadState<[PageComment]> = .idle
    private unowned let session: AppSession

    init(pageId: String, session: AppSession) {
        self.pageId = pageId
        self.session = session
    }

    /// Top-level comments (replies hang off them).
    var threads: [PageComment] { (state.value ?? []).filter { !$0.isReply } }
    /// Open comments: the number on the button.
    var openCount: Int { threads.filter { !$0.isResolved }.count }

    func replies(to comment: PageComment) -> [PageComment] {
        (state.value ?? []).filter { $0.parentCommentId == comment.id }
    }

    func comment(id: String) -> PageComment? {
        state.value?.first { $0.id == id }
    }

    enum Composing: Equatable {
        case new
        case reply(PageComment)
        case edit(PageComment)
    }

    /// What the comment sheet's composer writes, and its text: kept here rather than in the sheet, so closing it (Done,
    /// a swipe, a link, Show on Page) doesn't lose a comment being written. Cleared once it is sent.
    var composing = Composing.new
    var draft = ""

    /// The comment with this ID, loading the list again if it's unknown: a collaborator's new comment whose mark came
    /// through the live document already.
    func comment(id: String, reloadingIfMissing: Bool) async -> PageComment? {
        if let found = comment(id: id) { return found }
        guard reloadingIfMissing else { return nil }
        await load()
        return comment(id: id)
    }

    /// A reply or edit whose comment is gone meanwhile (deleted elsewhere) becomes a new comment, its text kept.
    func dropGoneTarget() {
        switch composing {
        case .reply(let target), .edit(let target):
            if comment(id: target.id) == nil { composing = .new }
        case .new: break
        }
    }

    /// Resolving is a licensed feature, as in the web client.
    var canResolve: Bool { session.ready?.entitlements.has("comment:resolution") == true }

    func load() async {
        guard let client = session.client else { return }
        if state.value == nil { state = .loading }
        do {
            let comments = try await Paginated.all { cursor in
                try await session.perform { try await client.send(Endpoints.Comments.list(pageId: self.pageId, cursor: cursor)) }
            }
            state = .loaded(comments)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }

    /// Page comment or reply.
    @discardableResult
    func create(text: String, replyTo: PageComment?) async throws -> PageComment {
        try await change(Endpoints.Comments.create(pageId: pageId, text: text, parentCommentId: replyTo?.id))
    }

    /// Inline comment on a passage; the editor then marks it with the returned ID.
    func createInline(text: String, selection: String) async throws -> PageComment {
        try await change(Endpoints.Comments.createInline(pageId: pageId, text: text, selection: selection))
    }

    func update(_ comment: PageComment, text: String) async throws {
        try await change(Endpoints.Comments.update(commentId: comment.id, text: text))
    }

    func delete(_ comment: PageComment) async throws {
        try await change(Endpoints.Comments.delete(commentId: comment.id))
    }

    func setResolved(_ comment: PageComment, _ resolved: Bool) async throws {
        try await change(Endpoints.Comments.resolve(commentId: comment.id, pageId: pageId, resolved: resolved))
    }

    @discardableResult
    private func change<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let response = try await session.send(endpoint)
        await load()
        return response
    }
}
