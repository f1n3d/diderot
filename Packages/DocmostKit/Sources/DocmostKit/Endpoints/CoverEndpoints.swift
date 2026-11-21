import Foundation

/// Page covers (Docmost 0.98): `pages/update` takes `coverPhoto` and `coverPosition` beside the title and icon, with
/// edit permission. Changing the cover puts its position back to the middle (null) unless the same request sends one.
extension Endpoints.Pages {
    public struct CoverBody: Encodable, Sendable {
        public let pageId: String
        /// Left out when nil; `.some(nil)` sends null, which removes the cover.
        public var coverPhoto: String??
        public var coverPosition: Double?

        private enum CodingKeys: String, CodingKey {
            case pageId, coverPhoto, coverPosition
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pageId, forKey: .pageId)
            switch coverPhoto {
            case .some(.some(let photo)): try container.encode(photo, forKey: .coverPhoto)
            case .some(.none): try container.encodeNil(forKey: .coverPhoto)
            case .none: break
            }
            try container.encodeIfPresent(coverPosition, forKey: .coverPosition)
        }
    }

    /// Sets the cover to a preset (`preset:<id>`) or an uploaded file (`coverPhoto(for:)`), or removes it (nil). Never
    /// to a stored Unsplash address: the server takes that for a file and refuses it ("Invalid cover photo").
    public static func setCover(pageId: String, coverPhoto: String?, position: Double? = nil) -> Endpoint<Page> {
        .post("pages/update", body: CoverBody(pageId: pageId, coverPhoto: .some(coverPhoto), coverPosition: position))
    }

    /// Moves the cover image vertically: 0 shows its top, 100 its bottom.
    public static func setCoverPosition(pageId: String, _ position: Double) -> Endpoint<Page> {
        .post("pages/update", body: CoverBody(pageId: pageId, coverPhoto: nil, coverPosition: position))
    }

    /// The `coverPhoto` that makes an upload (`APIClient.uploadCover`) the page's cover, as the web writes it:
    /// `/api/files/<id>/<name>`, the name encoded as JavaScript's `encodeURIComponent` does.
    public static func coverPhoto(for attachment: Attachment) -> String {
        "/api/files/\(attachment.id)/\(attachment.fileName.addingPercentEncoding(withAllowedCharacters: uriComponent) ?? attachment.fileName)"
    }

    /// What `encodeURIComponent` leaves as it is: ASCII letters and digits, and `-_.!~*'()`.
    private static let uriComponent = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
}
