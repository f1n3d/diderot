import Foundation
import Testing
@testable import DocmostKit

extension MockedNetworkingTests {
/// Docmost 0.98 moved the installed integrations to `integrations/installed` and answers `integrations` with the catalog
/// of those it offers; 0.97 knows only `integrations`, 0.96 neither. The client asks the new path first and falls back
/// on Docmost's own 404.
struct InstalledIntegrationsTests {
    private let installed = "/api/integrations/installed", before098 = "/api/integrations"
    private let github = Integration(id: "01a172c2-6382-7d3f-b043-e1d3faba47c4", type: "github", unfurlHosts: ["github.com"])

    private func notFound(_ path: String) -> MockURLProtocol.Response {
        .init(status: 404, body: Data(#"{"message":"Cannot POST \#(path)","error":"Not Found","statusCode":404}"#.utf8))
    }

    @Test func docmost098AnswersTheNewPath() async throws {
        MockURLProtocol.respond(byPath: [installed: .init(body: try TestSupport.fixture("integrations-installed"))])
        #expect(try await TestSupport.mockClient().installedIntegrations() == [github])
        #expect(MockURLProtocol.recordedRequests.map(\.url?.path) == [installed])
    }

    @Test func docmost097FallsBackToItsPath() async throws {
        MockURLProtocol.respond(byPath: [installed: notFound(installed), before098: .init(body: try TestSupport.fixture("integrations-installed"))])
        #expect(try await TestSupport.mockClient().installedIntegrations() == [github])
        #expect(MockURLProtocol.recordedRequests.map(\.url?.path) == [installed, before098])
    }

    @Test func docmost096KnowsNeither() async throws {
        MockURLProtocol.respond(byPath: [installed: notFound(installed), before098: notFound(before098)])
        await #expect(throws: APIError.notFound(message: "Cannot POST \(before098)")) {
            try await TestSupport.mockClient().installedIntegrations()
        }
    }

    /// Only Docmost's own 404 means an older server. Another failure doesn't ask the old path, which a 0.98 server
    /// answers with its catalog.
    @Test func otherFailuresDontFallBack() async throws {
        for failure in [MockURLProtocol.Response(status: 404, body: Data("<html>Not here</html>".utf8)),
                        MockURLProtocol.Response(status: 500, body: Data(#"{"statusCode":500,"message":"Internal server error"}"#.utf8))] {
            MockURLProtocol.respond(byPath: [installed: failure, before098: .init(body: try TestSupport.fixture("integrations-installed"))])
            await #expect(throws: APIError.self) { try await TestSupport.mockClient().installedIntegrations() }
            #expect(MockURLProtocol.recordedRequests.map(\.url?.path) == [installed], "HTTP \(failure.status)")
        }
    }
}
}
