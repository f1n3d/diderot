import Foundation

/// Response of `files/upload`, or an entry from `pages/attachments`.
public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileSize: Int?
    public let mimeType: String?

    public init(id: String, fileName: String, fileSize: Int? = nil, mimeType: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, fileSize, mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        // `bigint` arrives as a number or a string, depending on the driver.
        if let number = try? container.decodeIfPresent(Int.self, forKey: .fileSize) {
            fileSize = number
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .fileSize) {
            fileSize = Int(text)
        } else {
            fileSize = nil
        }
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    }

    /// Path as the web client writes it into image and attachment nodes.
    public var fileURLPath: String { "/api/files/\(id)/\(fileName)" }
    public var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    public var isVideo: Bool { mimeType?.hasPrefix("video/") == true }
    public var isAudio: Bool { mimeType?.hasPrefix("audio/") == true }
    public var isPDF: Bool { mimeType == "application/pdf" }

    public var contentNode: PMNode { contentNode(asAttachment: false) }

    /// Node for the page: image, video, audio and PDF embed, anything else is an attachment card. `asAttachment` always
    /// gives a card, like "File attachment" in the web editor.
    public func contentNode(asAttachment: Bool) -> PMNode {
        let size: JSONValue = fileSize.map { .number(Double($0)) } ?? .null
        if asAttachment {
            return attachmentNode(size: size)
        }
        if isImage {
            return PMNode(type: "image", attrs: ["src": .string(fileURLPath), "attachmentId": .string(id), "title": .string(fileName), "size": size, "align": "center"])
        }
        if isVideo {
            return PMNode(type: "video", attrs: ["src": .string(fileURLPath), "attachmentId": .string(id), "title": .string(fileName), "size": size, "align": "center"])
        }
        if isAudio {
            return PMNode(type: "audio", attrs: ["src": .string(fileURLPath), "attachmentId": .string(id), "title": .string(fileName), "size": size])
        }
        if isPDF {
            return PMNode(type: "pdf", attrs: ["src": .string(fileURLPath), "attachmentId": .string(id), "name": .string(fileName), "size": size])
        }
        return attachmentNode(size: size)
    }

    private func attachmentNode(size: JSONValue) -> PMNode {
        PMNode(type: "attachment", attrs: [
            "url": .string(fileURLPath), "name": .string(fileName), "mime": mimeType.map { .string($0) } ?? .null,
            "size": size, "attachmentId": .string(id),
        ])
    }
}
