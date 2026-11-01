import Foundation
import SwiftUI
import Testing
import DocmostKit
@testable import Diderot

/// A page as deep as its JSON can be (JSONDecoder stops at 512 levels, about 250 nodes inside each other) opens in the
/// reader and on the page, as the server sends it (`JSONValue` decodes 100 levels) and as the editor's engine does (whole):
/// down to `ContentParser.maxDepth` its content shows, a note stands for the rest. Decoding, the parser and the block views
/// go a level deeper in the stack per level, and such a page ended the app on every open (code review R35).
struct DeepContentTests {
    /// SwiftUI builds its accessibility tree only while assistive technology is on: as in `MediaBlockViewTests`.
    private static let accessibilityOn: Void = {
        let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(handle, name) { unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)(1) }
        }
    }()

    init() { _ = Self.accessibilityOn }

    enum Shape: String, CaseIterable {
        /// Quotes in quotes, a paragraph "Level n." in each: a node per level.
        case quotes
        /// Lists in list items, a paragraph "Level n." in each item: two nodes per level.
        case lists
        /// Unknown inline nodes in a paragraph, text innermost: one block, however deep its inline content.
        case inlines

        /// The page's content, `levels` deep.
        func document(_ levels: Int) -> String {
            func paragraph(_ level: Int) -> String { #"{"type":"paragraph","content":[{"type":"text","text":"Level \#(level)."}]},"# }
            let innermost = #"{"type":"paragraph","content":[{"type":"text","text":"Innermost"}]}"#
            let node = switch self {
            case .quotes:
                (1...levels).map { #"{"type":"blockquote","content":["# + paragraph($0) }.joined()
                    + innermost + String(repeating: "]}", count: levels)
            case .lists:
                (1...levels).map { #"{"type":"bulletList","content":[{"type":"listItem","content":["# + paragraph($0) }.joined()
                    + innermost + String(repeating: "]}]}", count: levels)
            case .inlines:
                #"{"type":"paragraph","content":[{"type":"text","text":"Level 1. "},"#
                    + String(repeating: #"{"type":"crafted","content":["#, count: levels) + #"{"type":"text","text":"Innermost"}"#
                    + String(repeating: "]}", count: levels) + "]}"
            }
            return #"{"type":"doc","content":[\#(node)]}"#
        }

        /// The page as the server sends it.
        func page(_ levels: Int) -> Data { Data(#"{"id":"p","content":\#(document(levels))}"#.utf8) }

        /// The deepest "Level n." shown: its paragraph's depth (quotes: n + 1, lists: 2n + 1) is at most `maxDepth`.
        var deepestShown: Int {
            switch self {
            case .quotes: ContentParser.maxDepth - 1
            case .lists: (ContentParser.maxDepth - 1) / 2
            case .inlines: 1
            }
        }
    }

    @Test(arguments: Shape.allCases)
    func deepestPageOpens(shape: Shape) async throws {
        let levels = try #require(stride(from: 300, through: 50, by: -1).first {
            (try? JSONDecoder().decode(Page.self, from: shape.page($0))) != nil
        })
        #expect(levels > ContentParser.maxDepth * 3, "JSONDecoder takes far deeper content than shows")
        let data = shape.page(levels)
        // Off the main thread, as the API client decodes and the history parses, where a thread's stack is smaller.
        let page = try await Task.detached { try JSONDecoder().decode(Page.self, from: data) }.value
        let document = await Task.detached { ContentDocument(json: page.content) }.value
        func model(_ document: PMNode?) -> DocumentModel {
            DocumentModel(page: page, initialDocument: document, engine: WebDocumentEngine(session: AppSession()), readOnlyReason: nil)
        }
        // As the engine sends it to the editor: decoded whole.
        let engineDocument = try JSONDecoder().decode(PMNode.self, from: Data(shape.document(levels).utf8))
        let note = String(localized: "Nested too deeply to show")

        for (name, view) in [
            ("reader", AnyView(ContentDocumentView(document: document))),
            ("page", AnyView(DocumentBody(model: model(nil)))),
            ("reader from the engine", AnyView(ContentDocumentView(document: ContentParser.parse(engineDocument)))),
            ("page from the engine", AnyView(DocumentBody(model: model(engineDocument)))),
        ] {
            let labels = try await shownLabels(of: ScrollView { view })
            func shows(_ text: String) -> Bool { labels.contains { $0.contains(text) } }
            #expect(shows("Level \(shape.deepestShown)."), "\(shape), \(name): content down to the deepest level shown shows")
            if shape != .inlines {
                #expect(!shows("Level \(shape.deepestShown + 1)."), "\(shape), \(name): deeper content doesn't show")
                #expect(shows(note), "\(shape), \(name): a note stands for it")
            }
        }
        if shape == .inlines {
            // Editing the paragraph: the editor keeps an unknown inline node whole, as JSON.
            var text = AttributedString()
            Self.withStack(left: 1 << 20) {
                text = InlineAttributedText.attributedString(from: engineDocument.children[0].children)
            }
            #expect(String(text.characters).hasPrefix("Level 1. "))
        }
    }

    /// The accessibility labels of `view` in a window once it shows "Level 1.", laid out first with the stack an iPhone's
    /// main thread has (1 MB; the simulator's has 8).
    private func shownLabels(of view: some View) async throws -> [String] {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        Self.withStack(left: 1 << 20) {
            window.isHidden = false
            window.layoutIfNeeded()
            _ = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.infinity))
        }
        defer { window.isHidden = true }
        var labels: [String] = []
        for _ in 0..<200 where !labels.contains(where: { $0.contains("Level 1.") }) {
            window.layoutIfNeeded()
            labels = Self.labels(in: window)
            try await Task.sleep(for: .milliseconds(50))
        }
        return labels
    }

    /// Runs `body` with only `bytes` of this thread's stack left.
    private static func withStack(left bytes: UInt, _ body: () -> Void) {
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        descend(to: top - UInt(pthread_get_stacksize_np(pthread_self())) + bytes, body)
    }

    /// Goes down the stack a small frame at a time to `address` and runs `body` there.
    @inline(never) private static func descend(to address: UInt, _ body: () -> Void) {
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        if here > address { descend(to: address, body) } else { body() }
        marker &+= 1
    }

    /// The accessibility labels VoiceOver can reach from `element`.
    private static func labels(in element: NSObject) -> [String] {
        let children = element.accessibilityElements as? [NSObject] ?? (element as? UIView)?.subviews ?? []
        return [element.accessibilityLabel].compactMap(\.self) + children.flatMap(labels)
    }
}
