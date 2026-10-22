import Foundation
import Testing
import DocmostKit

/// DocmostKit texts use the app's String Catalog: in German an untitled page reads "Ohne Titel" in the tree, search
/// and title bar as in Recently Opened, and API errors read in German.
struct KitTextTests {
    @Test func kitTextsUseTheAppsTranslations() {
        #expect(PageTitle.display(" ") == String(localized: "Untitled"))
        #expect(APIError.server(status: 502, message: nil).userMessage == String(localized: "Server error (\(502))."))
    }
}
