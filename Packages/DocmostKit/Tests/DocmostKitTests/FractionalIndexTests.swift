import Testing
@testable import DocmostKit

struct FractionalIndexTests {
    /// Reference values from the `fractional-indexing` documentation.
    @Test func referenceValues() throws {
        #expect(try FractionalIndex.keyBetween(nil, nil) == "a0")
        #expect(try FractionalIndex.keyBetween(nil, "a0") == "Zz")
        #expect(try FractionalIndex.keyBetween("a0", nil) == "a1")
        #expect(try FractionalIndex.keyBetween("a0", "a1") == "a0V")
        #expect(try FractionalIndex.keyBetween("a1", "a2") == "a1V")
        #expect(try FractionalIndex.keyBetween("a0V", "a1") == "a0l")
        #expect(try FractionalIndex.keyBetween("Zz", "a0") == "ZzV")
        #expect(try FractionalIndex.keyBetween("Zz", "a1") == "a0")
        #expect(try FractionalIndex.keyBetween(nil, "Y00") == "Xzzz")
        #expect(try FractionalIndex.keyBetween("bzz", nil) == "c000")
        #expect(try FractionalIndex.keyBetween("a0", "a0V") == "a0G")
        #expect(try FractionalIndex.keyBetween("a0", "a0G") == "a08")
        #expect(try FractionalIndex.keyBetween("b125", "b129") == "b127")
        #expect(try FractionalIndex.keyBetween("a0", "a1V") == "a1")
    }

    @Test func jitteredKeysStayInRangeAndLongEnough() throws {
        for _ in 0..<200 {
            let key = try FractionalIndex.jitteredKeyBetween("a0", "a1")
            #expect(key.count >= 5 && key.count <= 12)
            #expect(key > "a0" && key < "a1")
            #expect(!key.hasSuffix("0"))
            #expect(try FractionalIndex.keyBetween(key, "a1") > key)
        }
        let tight = try FractionalIndex.jitteredKeyBetween("a0", "a0V")
        #expect(tight > "a0" && tight < "a0V" && tight.count >= 5)
        let open = try FractionalIndex.jitteredKeyBetween(nil, nil)
        #expect(open.hasPrefix("a0") && open.count >= 5)
    }

    /// `pages/move` rejects keys over 12 characters; long neighbors still leave room for a 12-character key.
    @Test(arguments: [("a0VVVVVVVVV", "a0VVVVVVVVVV"), ("a0VVVVVVVVU", "a0VVVVVVVVV1"),
                      ("a0VVVVVVVVUz", "a0VVVVVVVVV1")])
    func jitteredKeyBetweenLongNeighboursFitsServerLimit(a: String, b: String) throws {
        let key = try FractionalIndex.jitteredKeyBetween(a, b)
        #expect(key.count <= 12)
        #expect(key > a && key < b)
    }

    /// Moving a page to the top repeatedly (drop before the first page) keeps keys short, like the web.
    @Test func movingToTheTopRepeatedlyKeepsKeysShort() throws {
        var first = try FractionalIndex.jitteredKeyBetween(nil, nil)
        for move in 1...200 {
            let key = try FractionalIndex.jitteredKeyBetween(nil, first)
            try #require(key < first && (5...12).contains(key.count), "move \(move): \(key) before \(first)")
            first = key
        }
    }

    /// Dropping pages repeatedly right after (or before) the same page: while a key of at most 12 characters fits
    /// between the neighbors, the jittered key is one.
    @Test(arguments: [true, false]) func droppingNextToTheSamePageRepeatedly(after: Bool) throws {
        for _ in 0..<20 {
            let page = try FractionalIndex.jitteredKeyBetween(nil, nil)
            var neighbour = after ? "a1" : "a0"
            for drop in 1... {
                let (a, b) = after ? (page, neighbour) : (neighbour, page)
                if try FractionalIndex.keyBetween(a, b).count > 12 { break }
                let key = try FractionalIndex.jitteredKeyBetween(a, b)
                try #require(a < key && key < b && (5...12).contains(key.count), "drop \(drop): \(a) < \(key) < \(b)")
                neighbour = key
            }
        }
    }

    /// Docmost's own keys (`fractional-indexing-jittered`) may end in "0", like "aI5E0" on the dev server.
    @Test(arguments: [("aI5E0", nil), (nil, "aI5E0"), ("aI5E0", "aI5F"), ("aI5D", "aI5E0"), (nil, "aI000"),
                      ("a0VVVVVVVVV", "a0VVVVVVVVW0")] as [(String?, String?)])
    func neighboursEndingInZero(a: String?, b: String?) throws {
        let low = a ?? "", high = b ?? "{"   // "{" sorts after every digit
        let key = try FractionalIndex.keyBetween(a, b)
        #expect(low < key && key < high)
        for _ in 0..<50 {
            let jittered = try FractionalIndex.jitteredKeyBetween(a, b)
            #expect(low < jittered && jittered < high && (5...12).contains(jittered.count))
        }
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: FractionalIndex.KeyError.self) { try FractionalIndex.keyBetween("a1", "a0") }
        #expect(throws: FractionalIndex.KeyError.self) { try FractionalIndex.keyBetween("0", nil) }
        // No key fits between these two.
        #expect(throws: FractionalIndex.KeyError.self) { try FractionalIndex.keyBetween("aI5E", "aI5E0") }
    }

    @Test func keysStayOrderedWhenInsertingRepeatedly() throws {
        var keys = ["a0", "a1"]
        for _ in 0..<40 {
            let middle = try FractionalIndex.keyBetween(keys[0], keys[1])
            #expect(keys[0] < middle && middle < keys[1])
            keys.insert(middle, at: 1)
        }
        var last = "a0"
        for _ in 0..<40 {
            let next = try FractionalIndex.keyBetween(last, nil)
            #expect(next > last)
            last = next
        }
    }
}
