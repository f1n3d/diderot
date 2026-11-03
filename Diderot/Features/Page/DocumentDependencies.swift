import Foundation
import DocmostKit

extension DocumentModel {
    /// What the model needs from outside its page, given by the page that makes it (`PageView`): the server and user
    /// it opened for, what the workspace offers, and the session's requests. Tests set what they use.
    struct Dependencies {
        /// The server the page is on: links to its pages, the uploads.
        var serverURL: URL?
        /// The signed-in user: the creator of the mentions they insert.
        var currentUserId: String?
        /// Whose cache (`LiveDocuments`) the engine's last document goes to on closing.
        var liveOwner: LiveDocuments.Owner?
        /// The server's installed integrations.
        var linkPreviews: LinkPreviewStore?
        /// Workspace has the `bases` license feature.
        var canCreateBases = false
        /// The server is Docmost 0.97 or newer: tabs, integration links and sorted sub-pages can be added (an older
        /// server's web couldn't show them).
        var hasDocmost097Features = false
        /// Suggestions for mentions and page links.
        var suggest: (@MainActor (String) async throws -> SearchSuggestions)?
        /// The page a link of this server points to (page mentions, database links).
        var lookUpPage: (@MainActor (String) async -> Page?)?
        /// Creates a database (base) as a subpage (`template` "kanban" or `nil`) and returns its page ID.
        var createBase: (@MainActor (String?) async throws -> String)?
        /// Sends a staged file to the server as an attachment of this page, bound to the session the page opened in.
        var sendUpload: (@MainActor (UploadFile) async throws -> Attachment)?
        /// Tells the whole app, also once the page is gone (an upload's error).
        var postAppNotice: (@MainActor (String) -> Void)?
        /// What the model's waits run on: a save's and the suggestions' wait for more input, the unsent changes' save,
        /// the waits for the text view and its focus. Tests move a clock of their own (`TestClock`).
        var clock: any Clock<Duration> = ContinuousClock()
    }
}
