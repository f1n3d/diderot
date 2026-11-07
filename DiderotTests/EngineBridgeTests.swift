import Foundation
import Testing
import WebKit
import DocmostKit
@testable import Diderot

extension AppSessionRaceTests {
    /// The app's calls reach the bundled engine (Diderot/Resources/Engine/engine.js) as `WebDocumentEngine` makes them, in
    /// a web page as in the app, and the answers read. A renamed operation or argument on either side, or another shape
    /// of answer, makes a call "unavailable": that passed CI, as only the local UI tests reached the engine, and broke
    /// every Return (code review V52). A collab server in the page (`StandInCollab`) serves an empty page; what the
    /// operations do to a document is Engine/tools' to check.
    @Suite struct EngineBridge: SessionStubbing {
        let store = SessionStore(keychain: MemorySecretStore())

        @MainActor @Test(.timeLimit(.minutes(3))) func everyOperationReachesTheEngine() async throws {
            let session = try await sessionOnA()
            defer { UnsentChanges.removeAll(server: a) }
            let engine = WebDocumentEngine(session: session, pageScripts: [StandInCollab.script])
            let seen = Seen()
            engine.onDocument = { _ in seen.documents += 1 }
            engine.onUnsentChangesKept = { seen.kept.append($0) }
            // WebKit starts its processes with the first page. On GitHub's runners, where this test may open the run's
            // first page, the engine then didn't start within the app's 15 s; a page loaded first starts them, and the
            // engine gets a second try.
            let firstPage = WebPage()
            for try await _ in firstPage.load(html: "<!doctype html><p>", baseURL: IslandHTML.baseURL) {}
            do {
                StubURLProtocol.body.withLock { $0 = #"{"data": {"token": "collab"}}"# }
                defer { StubURLProtocol.body.withLock { $0 = nil } }
                for attempt in 1...2 {
                    do {
                        try await engine.open(pageId: "bridge-\(UUID().uuidString)")
                        break
                    } catch where attempt < 2 {
                        continue
                    }
                }
            }
            // However the checks end (a failed `#require` has recorded its issue), the engine closes and the caches go.
            try? await exercise(engine, seen: seen)
            await engine.close()
            #expect(engine.status == .idle)
            await removeCaches()
        }

        /// Each operation once, through the Swift API.
        @MainActor private func exercise(_ engine: WebDocumentEngine, seen: Seen) async throws {
            try #require(await until { engine.status == .synced }, "The engine didn't sync: \(engine.status)")

            // Blocks, Return, Backspace.
            #expect(await engine.insertBlocks([paragraph("a", "Eins"), paragraph("b", "Zwei")], relativeTo: nil, position: .after) == .applied)
            let (a, aPath) = try await find("a", in: engine)
            guard case .moved(let line) = await engine.enter(a, keeping: paragraph("a", "Ei"), after: [text("ns")],
                                                             base: paragraph("a", "Eins")) else {
                Issue.record("Return didn't reach the engine")
                return
            }
            let next = try #require(await block(at: line.path, in: engine))
            let lineTarget = BlockTarget.path(line.path, type: "paragraph")
            #expect(await engine.backspacePlans(lineTarget)?.text == .join(aPath))
            #expect(await engine.backspace(lineTarget, holding: next, base: next) == .done(.join(aPath), cursor: EngineCursor(path: aPath, offset: 2)))

            // Conversions.
            #expect(await engine.conversions(a)?.contains("heading2") == true)
            guard case .moved = await engine.convert(a, to: "heading2") else {
                Issue.record("A conversion didn't reach the engine")
                return
            }
            let (heading, _) = try await find("a", in: engine)

            // Moving, replacing, placing.
            let (zweiBefore, _) = try await find("b", in: engine)
            #expect(await engine.moveBlock(zweiBefore, to: heading, position: .before) == .applied)
            let (b, bPath) = try await find("b", in: engine)
            let bBlock = try #require(await block(at: bPath, in: engine))
            #expect(await engine.replaceBlock(b, with: paragraph("b", "Zwei!"), base: bBlock, expected: nil) == .applied)
            let (replaced, _) = try await find("b", in: engine)
            let placed = await engine.placeBlocks([paragraph("c", "Drei")], at: replaced, position: .after, expected: nil)
            #expect(placed.result == .applied && placed.path == [bPath[0] + 1])
            let (c, cPath) = try await find("c", in: engine)
            #expect(await engine.fits(BlockPlace(target: c, position: .after), candidates: [[paragraph(nil, "x")]]) == [true])
            let drei = try #require(await block(at: cPath, in: engine))
            guard case .moved = await engine.enterLines(c, keeping: drei, lines: [[text("L1")], [text("L2")]], base: drei) else {
                Issue.record("Pasted lines didn't reach the engine")
                return
            }
            let (zwei, zweiPath) = try await find("b", in: engine)
            let zweiBlock = try #require(await block(at: zweiPath, in: engine))
            #expect(await engine.replaceBlock(zwei, withNodes: [paragraph("b", "B1"), paragraph("b2", "B2")], expected: zweiBlock) == .applied)
            #expect(await engine.batch([.insert([paragraph("e", "Fünf")], relativeTo: nil, position: .after),
                                        .delete(.id("e", path: []), expected: nil)]) == .applied)
            let (dreiNow, _) = try await find("c", in: engine)
            #expect(await engine.deleteBlock(dreiNow) == .applied)

            // A table, columns and a list.
            let table = PMNode(type: "table", content: [PMNode(type: "tableRow", content: [cell("1"), cell("2")])])
            let tablePath = try #require(await engine.placeBlocks([table], at: nil, position: .after, expected: nil).path)
            let tableTarget = BlockTarget.path(tablePath, type: "table")
            #expect(await engine.tableCommandsThatApply(tableTarget, cell: [0, 0], commands: [["name": "addRowAfter"], ["name": "mergeDown"]]) == [true, false])
            let command = await engine.tableCommand(tableTarget, cell: [0, 0], command: ["name": "addRowAfter"])
            #expect(command.result == .applied && command.focus != nil)
            let columns = PMNode(type: "columns", attrs: ["layout": "two_equal"], content: [column("x1"), column("x2")])
            let columnsPath = try #require(await engine.placeBlocks([columns], at: nil, position: .after, expected: nil).path)
            #expect(await engine.setColumnCount(.path(columnsPath, type: "columns"), count: 3) == .applied)
            #expect(await engine.setAttributes(.path(columnsPath, type: "columns"), attributes: ["layout": "three_left_wide"]) == .applied)
            let list = PMNode(type: "bulletList", content: ["i1", "i2", "i3"].map { PMNode(type: "listItem", content: [paragraph($0, $0)]) })
            let listPath = try #require(await engine.placeBlocks([list], at: nil, position: .after, expected: nil).path)
            #expect(await engine.splitContainer(after: .path(listPath + [0], type: "listItem")) == .applied)

            // A synced block, an embedded one and a comment's mark: each call's arguments find what they name.
            let source = PMNode(type: "transclusionSource", attrs: ["id": "s1"], content: [paragraph(nil, "Synchron")])
            let sourcePath = try #require(await engine.placeBlocks([source], at: nil, position: .after, expected: nil).path)
            #expect(await engine.unsync(.id("s1", path: sourcePath)) == .applied)
            #expect(await block(at: sourcePath, in: engine)?.type == "paragraph", "the synced block's content didn't stay")
            let embed = PMNode(type: "transclusionReference", attrs: ["sourcePageId": "page-s", "transclusionId": "s9"])
            let embedPath = try #require(await engine.placeBlocks([embed], at: nil, position: .after, expected: nil).path)
            #expect(await engine.replaceReference(at: embedPath, sourcePageId: "page-s", transclusionId: "s9", with: [paragraph(nil, "Kopie")]) == .applied)
            #expect(await block(at: embedPath, in: engine)?.plainText == "Kopie")
            let comment = PMMark(type: "comment", attrs: ["commentId": "c1", "resolved": false])
            let marked = PMNode(type: "paragraph", attrs: ["id": "m"], content: [PMNode(type: "text", marks: [comment], text: "markiert")])
            let markedPath = try #require(await engine.placeBlocks([marked], at: nil, position: .after, expected: nil).path)
            #expect(await engine.unsetComment("c1") == .applied)
            #expect(await block(at: markedPath, in: engine)?.children.first?.marks?.isEmpty ?? true, "the comment's mark stayed")

            // History.
            #expect(await engine.undo() == .applied)
            #expect(await engine.redo() == .applied)

            // What the page shows, and what it keeps: the stand-in confirms nothing.
            let document = try #require(await engine.currentDocument())
            #expect(document.children.map(\.plainText).contains("B2"))
            #expect(await until { seen.documents > 0 && engine.unconfirmedChanges > 0 })
            await engine.saveUnsentChanges()
            #expect(seen.kept.count == 1 && seen.kept.first.map { $0 == nil } == true, "the unsent changes weren't kept")
        }

        /// What the engine reported through the page's callbacks.
        @MainActor private final class Seen {
            var documents = 0
            var kept: [(any Error)?] = []
        }

        private func paragraph(_ id: String?, _ text: String) -> PMNode {
            PMNode(type: "paragraph", attrs: id.map { ["id": .string($0)] }, content: text.isEmpty ? nil : [PMNode(type: "text", text: text)])
        }

        /// Inline text: what follows the cursor on Return, a pasted line.
        private func text(_ value: String) -> PMNode {
            PMNode(type: "text", text: value)
        }

        private func cell(_ text: String) -> PMNode {
            PMNode(type: "tableCell", content: [paragraph(nil, text)])
        }

        private func column(_ text: String) -> PMNode {
            PMNode(type: "column", content: [paragraph(nil, text)])
        }

        /// The top-level block with this id and its path, where the engine has it now.
        @MainActor private func find(_ id: String, in engine: WebDocumentEngine) async throws -> (BlockTarget, [Int]) {
            let document = try #require(await engine.currentDocument())
            let index = try #require(document.children.firstIndex { $0.string("id") == id }, "No block “\(id)”")
            return (.id(id, path: [index]), [index])
        }

        @MainActor private func block(at path: [Int], in engine: WebDocumentEngine) async -> PMNode? {
            var node = await engine.currentDocument()
            for index in path {
                guard let children = node?.children, children.indices.contains(index) else { return nil }
                node = children[index]
            }
            return node
        }

        @MainActor private func until(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<300 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
    }
}

/// A collab server in the engine's page: a WebSocket in its place that answers as Docmost's Hocuspocus server does for
/// an empty page (sign-in accepted, the sync step with an empty document, pings) and confirms no change. After
/// Engine/tools/connection-check.ts, which checks the connection against the same stand-in.
enum StandInCollab {
    static let script = #"""
    (() => {
      // Hocuspocus messages in lib0's encoding: numbers in 7-bit groups, strings and byte arrays after their length.
      class Writer {
        constructor() { this.bytes = []; }
        uint(value) {
          while (value > 0x7f) { this.bytes.push(0x80 | (value & 0x7f)); value = Math.floor(value / 128); }
          this.bytes.push(value);
          return this;
        }
        array(value) { this.uint(value.length); this.bytes.push(...value); return this; }
        string(value) { return this.array(new TextEncoder().encode(value)); }
        done() { return Uint8Array.from(this.bytes); }
      }
      class Reader {
        constructor(bytes) { this.bytes = bytes; this.position = 0; }
        uint() {
          let value = 0;
          for (let factor = 1; ; factor *= 128) {
            if (this.position >= this.bytes.length) throw new Error("truncated message");
            const byte = this.bytes[this.position++];
            value += (byte & 0x7f) * factor;
            if (byte < 0x80) return value;
          }
        }
        array() {
          const length = this.uint();
          if (this.position + length > this.bytes.length) throw new Error("truncated message");
          this.position += length;
          return this.bytes.slice(this.position - length, this.position);
        }
        string() { return new TextDecoder().decode(this.array()); }
      }
      const sync = 0, auth = 2, ping = 9, authenticated = 2, syncStep1 = 0, syncStep2 = 1;
      // An empty Yjs document's update.
      const emptyDocument = Uint8Array.of(0, 0);
      class StandInSocket {
        constructor(url) {
          this.url = url;
          this.readyState = 0;
          this.binaryType = "arraybuffer";
          this.listeners = new Map();
          setTimeout(() => {
            this.readyState = 1;
            this.dispatch("open", {});
            this.pings = setInterval(() => this.answer(Uint8Array.of(ping)), 1000);
          }, 1);
        }
        addEventListener(type, listener) {
          if (!this.listeners.has(type)) this.listeners.set(type, new Set());
          this.listeners.get(type).add(listener);
        }
        removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
        send(data) {
          const bytes = Uint8Array.from(data instanceof ArrayBuffer ? new Uint8Array(data) : data);
          // A pong is the message type alone.
          if (bytes.length === 1) return;
          try {
            const message = new Reader(bytes);
            const name = message.string();
            const type = message.uint();
            if (type === auth) {
              this.answer(new Writer().string(name).uint(auth).uint(authenticated).string("read-write").done());
            } else if (type === sync && message.uint() === syncStep1) {
              this.answer(new Writer().string(name).uint(sync).uint(syncStep2).array(emptyDocument).done());
            }
          } catch {
            // Not a message the server answers.
          }
        }
        close() {
          if (this.readyState === 3) return;
          this.readyState = 3;
          clearInterval(this.pings);
          setTimeout(() => this.dispatch("close", { code: 1000, reason: "" }), 1);
        }
        answer(message) {
          setTimeout(() => { if (this.readyState === 1) this.dispatch("message", { data: message.buffer }); }, 1);
        }
        dispatch(type, event) { for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event); }
      }
      Object.assign(StandInSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
      window.WebSocket = StandInSocket;
    })();
    """#
}
