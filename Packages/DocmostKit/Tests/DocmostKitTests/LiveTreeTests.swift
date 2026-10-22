import Foundation
import Testing
@testable import DocmostKit

/// Page tree against the dev instance (opt-in like `LiveAPITests`): reorder, nest, trash, restore, delete for good.
@Suite(.serialized, .enabled(if: LiveEnvironment.isConfigured))
struct LiveTreeTests {
    @Test func movesPagesWithFractionalPositionsAndUsesTrash() async throws {
        let client = try await LiveSession.shared.client()
        let space = try await client.send(Endpoints.Spaces.info(spaceId: "demo"))
        let stamp = Int(Date().timeIntervalSince1970)
        let first = try await client.send(Endpoints.Pages.create(spaceId: space.id, title: "Tree A \(stamp)"))
        defer { _ = try? await client.send(Endpoints.Pages.delete(pageId: first.id, permanently: true)) }
        let second = try await client.send(Endpoints.Pages.create(spaceId: space.id, title: "Tree B \(stamp)"))
        defer { _ = try? await client.send(Endpoints.Pages.delete(pageId: second.id, permanently: true)) }

        func rootPages() async throws -> [SidebarPage] {
            try await client.send(Endpoints.Pages.sidebar(spaceId: space.id, limit: 100)).items
        }

        // Move B before A: position between A's predecessor and A.
        var roots = try await rootPages()
        let indexA = try #require(roots.firstIndex { $0.id == first.id })
        let lower = indexA > 0 ? roots[indexA - 1].position : nil
        let position = try FractionalIndex.jitteredKeyBetween(lower, roots[indexA].position)
        _ = try await client.send(Endpoints.Pages.move(pageId: second.id, position: position, parentPageId: nil))
        roots = try await rootPages()
        let newIndexA = try #require(roots.firstIndex { $0.id == first.id })
        let newIndexB = try #require(roots.firstIndex { $0.id == second.id })
        #expect(newIndexB == newIndexA - 1)

        // Nest B under A.
        _ = try await client.send(Endpoints.Pages.move(pageId: second.id, position: try FractionalIndex.jitteredKeyBetween(nil, nil), parentPageId: first.id))
        let children = try await client.send(Endpoints.Pages.children(of: first.id)).items
        #expect(children.map(\.id) == [second.id])

        // Trash: delete B, list the trash, restore.
        _ = try await client.send(Endpoints.Pages.delete(pageId: second.id))
        let trash = try await client.send(Endpoints.Pages.trash(spaceId: space.id)).items
        #expect(trash.contains { $0.id == second.id })
        _ = try await client.send(Endpoints.Pages.restore(pageId: second.id))
        let restored = try await client.send(Endpoints.Pages.info(pageId: second.id))
        #expect(!restored.isInTrash)
    }
}
