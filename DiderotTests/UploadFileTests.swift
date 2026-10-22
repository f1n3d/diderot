import Foundation
import Testing
@testable import Diderot

struct UploadFileTests {
    /// Everyone sees upload names on the web, so the stamp ignores the uploader's calendar and digits.
    @Test func cameraNameHasGregorianStamp() throws {
        let name = UploadFile.camera(Data()).fileName
        let year = try #require(name.wholeMatch(of: /Foto-(\d{4})\d{4}-\d{6}\.jpg/.asciiOnlyDigits())?.1)
        #expect(Int(year) == Calendar(identifier: .gregorian).component(.year, from: .now))
    }
}
