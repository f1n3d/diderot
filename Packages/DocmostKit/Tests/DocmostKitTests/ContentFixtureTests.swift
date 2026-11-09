import Foundation
import Testing
@testable import DocmostKit

/// Decodes recorded responses from the "Demo" space of the dev instance.
struct ContentFixtureTests {
    @Test func spacesListWithMembership() throws {
        let spaces = try TestSupport.decodeFixture(Paginated<Space>.self, "spaces")
        #expect(spaces.items.count == 2)
        let demo = try #require(spaces.items.first { $0.slug == "demo" })
        #expect(demo.name == "Demo")
        #expect(demo.role == .admin)
        #expect(demo.memberCount == 1)
        #expect(spaces.meta.hasNextPage == false)
    }

    @Test func spaceInfoPermissions() throws {
        let space = try TestSupport.decodeFixture(Space.self, "space-info")
        let membership = try #require(space.membership)
        #expect(membership.spaceRole == .admin)
        #expect(membership.can("manage", "page"))
        #expect(membership.can("read", "settings"))
        #expect(!membership.can("delete", "workspace"))
        #expect(membership.canEditPages)
    }

    @Test func sidebarRootIncludesUntitledPage() throws {
        let root = try TestSupport.decodeFixture(Paginated<SidebarPage>.self, "sidebar-pages-root")
        #expect(root.items.count == 6)
        #expect(root.items.filter(\.mayHaveChildren).count == 5)
        let untitled = try #require(root.items.first { $0.title == nil })
        #expect(untitled.displayTitle == "Untitled")
        #expect(untitled.icon == nil)
        #expect(root.items.allSatisfy { $0.parentPageId == nil })
        #expect(root.items.allSatisfy { $0.canEdit == true })
    }

    @Test func sidebarChildrenAndPaging() throws {
        let children = try TestSupport.decodeFixture(Paginated<SidebarPage>.self, "sidebar-pages-children")
        #expect(children.items.count == 3)
        #expect(children.items.allSatisfy { $0.parentPageId != nil })

        let paged = try TestSupport.decodeFixture(Paginated<SidebarPage>.self, "sidebar-pages-paged")
        #expect(paged.items.count == 2)
        #expect(paged.meta.hasNextPage)
        #expect(paged.meta.nextCursor?.isEmpty == false)
    }

    @Test func breadcrumbsAreRootFirst() throws {
        let crumbs = try TestSupport.decodeFixture([Breadcrumb].self, "breadcrumbs")
        #expect(crumbs.map(\.displayTitle) == ["Handbuch", "Handbuch – Kapitel 1", "Handbuch – Abschnitt 1.1"])
        #expect(crumbs.first?.icon == "📘")
    }

    @Test func recentPagesCarrySpace() throws {
        let recent = try TestSupport.decodeFixture(Paginated<Page>.self, "recent-pages")
        #expect(recent.items.count == 5)
        #expect(recent.items.allSatisfy { $0.space?.slug == "demo" })
        let dates = recent.items.compactMap(\.updatedAt)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func pageInfoHasContentAndPermissions() throws {
        let page = try TestSupport.decodeFixture(Page.self, "page-info")
        #expect(page.displayTitle == "Handbuch – Abschnitt 1.1")
        #expect(page.icon == "🔹")
        #expect(page.canEdit)
        #expect(!page.isInTrash)
        #expect(page.space?.name == "Demo")
        #expect(page.creator?.name == "Dev Admin")
        #expect(page.content?["type"]?.stringValue == "doc")
        #expect(page.content?["content"]?.arrayValue?.count == 5)
    }

    /// "Append Note" refuses pages with footnotes: Docmost's append would put the note after them.
    @Test func footnotesAreFoundAtTheTopLevel() throws {
        func page(_ content: JSONValue?) throws -> Page {
            let body: JSONValue = ["id": "p1", "content": content ?? .null]
            return try JSONDecoding.makeDecoder().decode(Page.self, from: JSONEncoder().encode(body))
        }
        let paragraph: JSONValue = ["type": "paragraph", "content": [["type": "text", "text": "Hello"]]]
        let footnotes: JSONValue = ["type": "footnotes", "content": [
            ["type": "footnote", "attrs": ["id": "fn:1", "data-id": "one"], "content": [paragraph]],
        ]]
        #expect(try page(["type": "doc", "content": [paragraph, footnotes]]).hasFootnotes)
        // As Docmost's append leaves a page: a block after the footnotes.
        #expect(try page(["type": "doc", "content": [paragraph, footnotes, paragraph]]).hasFootnotes)
        #expect(try !page(["type": "doc", "content": [paragraph]]).hasFootnotes)
        // A footnote reference alone, or "footnotes" as text, isn't the block.
        #expect(try !page(["type": "doc", "content": [["type": "paragraph", "content": [
            ["type": "footnoteReference", "attrs": ["data-id": "one"]], ["type": "text", "text": "footnotes"],
        ]]]]).hasFootnotes)
        #expect(try !page(.string("Text with [^1]\n\n[^1]: A footnote")).hasFootnotes)
        #expect(try !page(nil).hasFootnotes)
        #expect(try !TestSupport.decodeFixture(Page.self, "page-info").hasFootnotes)
    }

    @Test func pageTitleFallback() {
        #expect(PageTitle.display(nil) == "Untitled")
        #expect(PageTitle.display("  ") == "Untitled")
        #expect(PageTitle.display(" Hello ") == "Hello")
    }
}
