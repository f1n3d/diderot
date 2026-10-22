import Foundation
import Testing
@testable import DocmostKit

/// Dev instance responses for the kanban template ("Kanban-Test" with three cards).
struct BaseFixtureTests {
    @Test func baseInfo() throws {
        let base = try TestSupport.decodeFixture(Base.self, "base-info")
        #expect(base.displayTitle == "Kanban-Test")
        #expect(base.canEdit)
        #expect(base.primaryProperty?.name == "Title")
        #expect(base.primaryProperty?.kind == .text)
        let status = try #require(base.properties.first { $0.kind == .status })
        #expect(status.typeOptions?["choices"]?.arrayValue?.count == 3)
        let view = try #require(base.views.first)
        #expect(view.kind == .kanban)
        #expect(view.config?["groupByPropertyId"]?.stringValue == status.id)
    }

    @Test func baseRows() throws {
        let page = try TestSupport.decodeFixture(BaseRowsPage.self, "base-rows")
        #expect(page.items.count == 3)
        #expect(!page.meta.hasNextPage)
        let base = try TestSupport.decodeFixture(Base.self, "base-info")
        let title = try #require(base.primaryProperty)
        #expect(page.items.compactMap { $0.cells[title.id]?.stringValue }.sorted() == ["Karte 1", "Karte 2", "Karte 3"])
        #expect(page.items.allSatisfy { $0.position != nil && $0.createdAt != nil })
    }

    @Test func unknownTypesStayReadable() {
        let property = BaseProperty(id: "prpx", name: "Neu", type: "rollup", position: nil, isPrimary: false, typeOptions: nil)
        #expect(property.kind == nil)
        let view = BaseView(id: "v", name: "Kalender", type: "calendar", position: nil, config: nil)
        #expect(view.kind == .table)
    }
}
