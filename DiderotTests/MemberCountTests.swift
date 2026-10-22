import Foundation
import Testing

/// The member chip in a space's header (SpaceView) reads "1 member" and "1 Mitglied" for a single member.
struct MemberCountTests {
    @Test func oneMemberIsSingular() throws {
        func bundle(_ language: String) throws -> Bundle {
            try #require(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
        }
        let en = try bundle("en"), de = try bundle("de")
        #expect(String(localized: "\(1) members", bundle: en) == "1 member")
        #expect(String(localized: "\(2) members", bundle: en) == "2 members")
        #expect(String(localized: "\(1) members", bundle: de) == "1 Mitglied")
        #expect(String(localized: "\(2) members", bundle: de) == "2 Mitglieder")
    }
}
