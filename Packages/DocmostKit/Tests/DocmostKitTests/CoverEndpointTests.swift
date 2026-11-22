import Foundation
import Testing
@testable import DocmostKit

/// Page covers (Docmost 0.98): the fields a page brings, what `pages/update` gets, and the value an upload becomes.
struct CoverEndpointTests {
    /// `pages/info` names the cover and its position; older servers send `coverPhoto: null` and no position.
    @Test func pagesReadTheirCover() throws {
        let page = try JSONDecoding.makeDecoder().decode(Page.self, from: Data(#"""
            {"id": "p1", "coverPhoto": "preset:gradient-sky", "coverPosition": 33.33,
             "coverAttribution": null, "updatedAt": "2026-11-21T01:11:19.958Z"}
            """#.utf8))
        #expect(page.coverPhoto == "preset:gradient-sky")
        #expect(page.coverPosition == 33.33)
        let older = try JSONDecoding.makeDecoder().decode(Page.self, from: Data(#"{"id": "p1", "coverPhoto": null}"#.utf8))
        #expect(older.coverPhoto == nil)
        #expect(older.coverPosition == nil)
    }

    /// A new cover sends only the cover (the server puts the position back to the middle), with a position if one comes
    /// along; removing it sends null; moving it sends only the position.
    @Test func coverChangesSendOnlyWhatChanges() throws {
        let preset = Endpoints.Pages.setCover(pageId: "p1", coverPhoto: "preset:color-red")
        #expect(preset.path == "pages/update")
        #expect(try body(of: preset) == ["pageId": "p1", "coverPhoto": "preset:color-red"])
        let restored = Endpoints.Pages.setCover(pageId: "p1", coverPhoto: "/api/files/a1/cover.jpg", position: 70)
        #expect(try body(of: restored) == ["pageId": "p1", "coverPhoto": "/api/files/a1/cover.jpg", "coverPosition": 70])
        #expect(try body(of: Endpoints.Pages.setCover(pageId: "p1", coverPhoto: nil)) == ["pageId": "p1", "coverPhoto": nil])
        let moved = Endpoints.Pages.setCoverPosition(pageId: "p1", 12.5)
        #expect(moved.path == "pages/update")
        #expect(try body(of: moved) == ["pageId": "p1", "coverPosition": 12.5])
    }

    /// The upload's name goes into the address as `encodeURIComponent` writes it: a slash, a question mark or a hash
    /// would end the server's file pattern.
    @Test func anUploadBecomesTheCoverByItsAddress() throws {
        let attachment = Attachment(id: "019a1f00-0000-7000-8000-0000000000aa", fileName: "Team offsite #1/ä(2)!.jpg")
        #expect(Endpoints.Pages.coverPhoto(for: attachment)
            == "/api/files/019a1f00-0000-7000-8000-0000000000aa/Team%20offsite%20%231%2F%C3%A4(2)!.jpg")
        #expect(Endpoints.Pages.coverPhoto(for: Attachment(id: "a1", fileName: "Probe_cover__1.jpg")) == "/api/files/a1/Probe_cover__1.jpg")
    }
}

extension MockedNetworkingTests {
    struct CoverUploadTests {
        /// A cover goes to `files/upload` as an attachment of the type `page-cover`, named before the file: the server
        /// reads only the fields that come first. The upload carries the bearer token, and the answer has no envelope
        /// (the server's `res.send`).
        @Test func coverUploadNamesItsTypeBeforeTheFile() async throws {
            MockURLProtocol.respond(with: .init(body: Data(#"{"id":"a1","fileName":"cover.jpg","fileSize":4,"mimeType":"image/jpeg","type":"page-cover"}"#.utf8)))
            let attachment = try await TestSupport.mockClient(token: "abc").uploadCover(
                pageId: "p1", fileName: "cover.jpg", mimeType: "image/jpeg", data: Data("JPEG".utf8))
            #expect(attachment.id == "a1")

            let request = try #require(MockURLProtocol.recordedRequests.first)
            #expect(request.url?.absoluteString == "http://localhost:3000/api/files/upload")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
            let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
            let boundary = contentType.trimmingPrefix("multipart/form-data; boundary=")
            let expected = "--\(boundary)\r\nContent-Disposition: form-data; name=\"pageId\"\r\n\r\np1\r\n"
                + "--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\npage-cover\r\n"
                + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nJPEG\r\n"
                + "--\(boundary)--\r\n"
            #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == expected)
        }
    }
}
