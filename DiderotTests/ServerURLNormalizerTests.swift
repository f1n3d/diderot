import Foundation
import Testing
@testable import Diderot

struct ServerURLNormalizerTests {
    @Test func addsHTTPSAndStripsPaths() {
        #expect(ServerURLNormalizer.normalize("wiki.example.com")?.absoluteString == "https://wiki.example.com")
        #expect(ServerURLNormalizer.normalize(" https://wiki.example.com/login?x=1#top ")?.absoluteString == "https://wiki.example.com")
        #expect(ServerURLNormalizer.normalize("HTTP://wiki.example.com:8080/")?.absoluteString == "http://wiki.example.com:8080")
        #expect(ServerURLNormalizer.normalize("10.example.com")?.absoluteString == "https://10.example.com")
        #expect(ServerURLNormalizer.normalize("172.32.0.1")?.absoluteString == "https://172.32.0.1")
    }

    @Test func localHostsDefaultToHTTP() {
        #expect(ServerURLNormalizer.normalize("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(ServerURLNormalizer.normalize("macbook.local:3000")?.absoluteString == "http://macbook.local:3000")
        #expect(ServerURLNormalizer.normalize("172.20.1.2:3000")?.absoluteString == "http://172.20.1.2:3000")
        #expect(ServerURLNormalizer.normalize("[::1]:3000")?.absoluteString == "http://[::1]:3000")
        #expect(ServerURLNormalizer.normalize("192.168.1.5:3000")?.absoluteString == "http://192.168.1.5:3000")
        #expect(ServerURLNormalizer.normalize("10.0.0.5:3000")?.absoluteString == "http://10.0.0.5:3000")
        #expect(ServerURLNormalizer.normalize("127.0.0.1:3000")?.absoluteString == "http://127.0.0.1:3000")
        #expect(ServerURLNormalizer.normalize("https://localhost:3000")?.absoluteString == "https://localhost:3000")
    }

    @Test func rejectsGarbage() {
        #expect(ServerURLNormalizer.normalize("") == nil)
        #expect(ServerURLNormalizer.normalize("   ") == nil)
        #expect(ServerURLNormalizer.normalize("ftp://wiki.example.com") == nil)
        #expect(ServerURLNormalizer.normalize("https://") == nil)
    }
}
