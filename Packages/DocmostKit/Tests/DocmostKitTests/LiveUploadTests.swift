import Foundation
import Testing
@testable import DocmostKit

/// Upload round trip on the dev instance (opt-in like `LiveAPITests`), fetching the file with the bearer token.
@Suite(.serialized, .enabled(if: LiveEnvironment.isConfigured))
struct LiveUploadTests {
    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    @Test func uploadsImageAndServesItBack() async throws {
        let client = try await LiveSession.shared.client()
        let space = try await client.send(Endpoints.Spaces.info(spaceId: "demo"))
        let page = try await client.send(Endpoints.Pages.create(spaceId: space.id, title: "Upload test \(Int(Date().timeIntervalSince1970))"))
        defer { _ = try? await client.send(Endpoints.Pages.delete(pageId: page.id, permanently: true)) }

        let attachment = try await client.uploadAttachment(pageId: page.id, fileName: "pixel.png", mimeType: "image/png", data: Self.pixel)
        #expect(attachment.isImage)
        #expect(attachment.fileName.hasSuffix(".png"))
        #expect(attachment.fileSize == Self.pixel.count)

        let node = attachment.contentNode
        #expect(node.type == "image")
        #expect(node.string("src") == attachment.fileURLPath)
        #expect(node.string("attachmentId") == attachment.id)

        let url = try #require(LiveEnvironment.url).appending(path: String(attachment.fileURLPath.dropFirst()))
        let (data, response) = try await client.fetchFile(at: url)
        #expect(response.statusCode == 200)
        #expect(data.count == Self.pixel.count)
        // Also deleted here so a failing delete fails the test; the deferred one ignores errors.
        _ = try await client.send(Endpoints.Pages.delete(pageId: page.id, permanently: true))
    }
}
