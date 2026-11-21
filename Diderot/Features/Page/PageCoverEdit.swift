import Foundation
import DocmostKit

/// How the cover's views change it through the page (`PageView`): in the session the page loaded in, then loading the
/// page again, as the header's icon does. The views get none where the cover can't be changed.
struct PageCoverActions {
    let edits: PageEdits
    let reload: () async -> Void
    let report: (String) -> Void
}

/// A page's cover while it changes (`PageCoverBand`, `AddCoverButton`): the change shows at once and stays until the
/// page has loaded again with it, and changes go out one after another, as the web queues them per page
/// (`usePageCover`), so a quick second pick can't reach the server before the first.
@MainActor
@Observable
final class PageCoverEdit {
    /// What `coverPhoto` and `coverPosition` say, or are about to.
    struct Fields: Equatable {
        var photo: String?
        var position: Double?
    }

    enum Change: Equatable {
        /// A preset (`preset:<id>`), an uploaded file's path, or none; the position comes back with a cover taken back.
        case photo(String?, position: Double? = nil)
        case position(Double)
    }

    /// The cover shown instead of the page's while a change is on its way.
    private(set) var pending: Fields?
    /// The image moves up and down: the band takes drags instead of the page (`PageView` stops its scrolling).
    var isRepositioning = false
    private(set) var isUploading = false
    @ObservationIgnored private var queue: Task<Void, Never>?
    /// Counts the changes: only the newest loads the page again and ends `pending`.
    @ObservationIgnored private var latest = 0
    /// An older change went out without the page loading again.
    @ObservationIgnored private var unloaded = false

    func fields(of page: Page) -> Fields {
        pending ?? Fields(photo: page.coverPhoto, position: page.coverPosition)
    }

    /// Shows a change at once and sends it after the ones before it; `shown` is the cover as the band shows it. The task
    /// tells whether the server took it; it says so if not, as the web does ("Failed to update cover").
    @discardableResult
    func send(_ change: Change, shown: Fields, with actions: PageCoverActions) -> Task<Bool, Never> {
        let fields = switch change {
        case .photo(let photo, let position): Fields(photo: photo, position: photo == nil ? nil : position)
        case .position(let position): Fields(photo: shown.photo, position: position)
        }
        latest += 1
        let id = latest
        pending = fields
        return enqueue {
            do {
                switch change {
                case .photo(let photo, let position): try await actions.edits.setCover(photo, position: position)
                case .position(let position): try await actions.edits.setCoverPosition(position)
                }
            } catch {
                if !(error is CancellationError) { actions.report(String(localized: "Failed to update cover")) }
                guard id == self.latest else { return false }
                self.pending = nil
                // What an older change set is on the server, not yet on the page.
                if self.unloaded { await self.reloaded(with: actions) }
                return false
            }
            if id == self.latest {
                await self.reloaded(with: actions)
                if id == self.latest { self.pending = nil }
            } else {
                self.unloaded = true
            }
            return true
        }
    }

    /// Uploads a picked image and makes it the cover; `prepare` reads and converts it (`CoverImage`). Returns whether
    /// it became the cover. A failed upload says why in the server's words where it gives them ("Cover image must be 5
    /// MB or smaller"), as the web does.
    func upload(_ prepare: @escaping @Sendable () async throws -> CoverImage.File?, shown: Fields, with actions: PageCoverActions) async -> Bool {
        guard !isUploading else { return false }
        isUploading = true
        defer { isUploading = false }
        let attachment: Attachment
        do {
            guard let file = try await prepare() else { return false }
            attachment = try await actions.edits.uploadCover(file)
        } catch is CancellationError {
            return false
        } catch let error as CoverImage.Unusable {
            actions.report(error.localizedDescription)
            return false
        } catch {
            actions.report(error is APIError ? error.userMessage : String(localized: "Failed to upload image"))
            return false
        }
        return await send(.photo(Endpoints.Pages.coverPhoto(for: attachment)), shown: shown, with: actions).value
    }

    private func reloaded(with actions: PageCoverActions) async {
        unloaded = false
        await actions.reload()
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = queue
        let task = Task {
            await previous?.value
            return await work()
        }
        queue = Task { _ = await task.value }
        return task
    }
}

extension PageEdits {
    /// Sets the cover (`preset:<id>`, an uploaded file's path) or removes it (nil); the server puts the position back to
    /// the middle unless `position` comes along.
    func setCover(_ photo: String?, position: Double? = nil) async throws {
        _ = try await session.send(Endpoints.Pages.setCover(pageId: page.id, coverPhoto: photo, position: position), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    func setCoverPosition(_ position: Double) async throws {
        _ = try await session.send(Endpoints.Pages.setCoverPosition(pageId: page.id, position), on: owner)
        changes.pageChanged(in: page.spaceId)
    }

    /// Uploads an image for the cover; `setCover` with its path makes it the cover.
    func uploadCover(_ file: CoverImage.File) async throws -> Attachment {
        let pageId = page.id
        return try await session.perform(on: owner) { client in
            try await client.uploadCover(pageId: pageId, fileName: file.fileName, mimeType: file.mimeType, data: file.data)
        }
    }
}
