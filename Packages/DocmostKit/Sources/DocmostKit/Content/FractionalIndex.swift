import Foundation

/// Sort keys as on the web (`fractional-indexing-jittered`): base-62 strings in plain string order, an integer part
/// plus a fraction. Docmost's fractions may end in "0" ("aI5E0"); ours never do, so they always leave room for a key
/// in between. The server validates `pages/move` positions with the same library.
public enum FractionalIndex {
    public enum KeyError: Error, Equatable {
        case invalidKey(String)
        case wrongOrder(String, String)
        case outOfRange
    }

    static let digits: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let smallestInteger = "A" + String(repeating: "0", count: 26)

    /// Key between `a` and `b` (`nil` = open end); `a0` when both are `nil`.
    public static func keyBetween(_ a: String?, _ b: String?) throws -> String {
        let a = try a.map(normalized), b = try b.map(normalized)
        if let a, let b, a >= b { throw KeyError.wrongOrder(a, b) }

        guard let a else {
            guard let b else { return "a0" }
            let ib = try integerPart(b)
            let fb = String(b.dropFirst(ib.count))
            if ib == smallestInteger { return ib + (try midpoint("", fb)) }
            // Always the next lower integer, as on the web: repeated moves to the top keep keys short.
            guard let decremented = decrement(ib) else { throw KeyError.outOfRange }
            return decremented
        }
        guard let b else {
            let ia = try integerPart(a)
            let fa = String(a.dropFirst(ia.count))
            if let incremented = increment(ia) { return incremented }
            return ia + (try midpoint(fa, nil))
        }
        let ia = try integerPart(a)
        let fa = String(a.dropFirst(ia.count))
        let ib = try integerPart(b)
        let fb = String(b.dropFirst(ib.count))
        if ia == ib { return ia + (try midpoint(fa, fb)) }
        guard let incremented = increment(ia) else { throw KeyError.outOfRange }
        if incremented < b { return incremented }
        return ia + (try midpoint(fa, nil))
    }

    /// `keyBetween` plus a random suffix (like the web's `fractional-indexing-jittered`). Always between `a` and `b`,
    /// with the 5–12 characters `pages/move` requires whenever such a key exists.
    public static func jitteredKeyBetween(_ a: String?, _ b: String?) throws -> String {
        let base = try keyBetween(a, b)
        // A suffix could pass `b` if the base is a prefix of it: take a key below the base, else the base, else above.
        if let b, b.hasPrefix(base) {
            let below = try jitteredKeyBetween(a, base)
            if below.count <= 12 { return below }
            return base.count >= 5 ? base : try jitteredKeyBetween(base, b)
        }
        var key = base
        while key.count < min(12, max(5, base.count + 2)) {
            key.append(digits[Int.random(in: 1..<digits.count)])   // never a trailing "0", see the type's comment
        }
        return key
    }

    // MARK: - Internal

    private static func integerLength(_ head: Character) -> Int? {
        guard let scalar = head.unicodeScalars.first?.value else { return nil }
        switch scalar {
        case 97...122: return Int(scalar - 97) + 2   // a…z
        case 65...90: return Int(90 - scalar) + 2    // A…Z
        default: return nil
        }
    }

    private static func integerPart(_ key: String) throws -> String {
        guard let head = key.first, let length = integerLength(head), length <= key.count else { throw KeyError.invalidKey(key) }
        return String(key.prefix(length))
    }

    /// Checks `key` and drops trailing "0"s from its fraction ("aI5E0" → "aI5E"). For the upper bound that only narrows
    /// the range; for the lower bound it is safe: a result above "aI5E" never ends in "0", so it is above "aI5E0" too.
    private static func normalized(_ key: String) throws -> String {
        if key == smallestInteger { throw KeyError.invalidKey(key) }
        let integer = try integerPart(key)
        for character in key where !digits.contains(character) { throw KeyError.invalidKey(key) }
        var fractional = key.dropFirst(integer.count)
        while fractional.last == "0" { fractional.removeLast() }
        return integer + fractional
    }

    private static func index(of character: Character) -> Int { digits.firstIndex(of: character) ?? 0 }

    private static func increment(_ integer: String) -> String? {
        var characters = Array(integer)
        let head = characters.removeFirst()
        var carry = true
        var i = characters.count - 1
        while carry && i >= 0 {
            let d = index(of: characters[i]) + 1
            if d == digits.count {
                characters[i] = "0"
            } else {
                characters[i] = digits[d]
                carry = false
            }
            i -= 1
        }
        guard carry else { return String(head) + String(characters) }
        if head == "Z" { return "a0" }
        if head == "z" { return nil }
        let next = Character(UnicodeScalar(head.unicodeScalars.first!.value + 1)!)
        if next > "a" { characters.append("0") } else { characters.removeLast() }
        return String(next) + String(characters)
    }

    private static func decrement(_ integer: String) -> String? {
        var characters = Array(integer)
        let head = characters.removeFirst()
        var borrow = true
        var i = characters.count - 1
        while borrow && i >= 0 {
            let d = index(of: characters[i]) - 1
            if d == -1 {
                characters[i] = digits[digits.count - 1]
            } else {
                characters[i] = digits[d]
                borrow = false
            }
            i -= 1
        }
        guard borrow else { return String(head) + String(characters) }
        if head == "a" { return "Z" + String(digits[digits.count - 1]) }
        if head == "A" { return nil }
        let previous = Character(UnicodeScalar(head.unicodeScalars.first!.value - 1)!)
        // Uppercase heads: the lower the letter, the longer the integer part.
        if previous < "Z" { characters.append(digits[digits.count - 1]) } else { characters.removeLast() }
        return String(previous) + String(characters)
    }

    /// Fractional part between `a` and `b` (`b == nil` = open upward); `a` may be empty.
    private static func midpoint(_ a: String, _ b: String?) throws -> String {
        if let b, a >= b { throw KeyError.wrongOrder(a, b) }
        let aChars = Array(a)
        if let b {
            let bChars = Array(b)
            var n = 0
            while n < bChars.count, (n < aChars.count ? aChars[n] : "0") == bChars[n] { n += 1 }
            if n > 0 {
                return String(bChars.prefix(n)) + (try midpoint(String(aChars.dropFirst(n)), String(bChars.dropFirst(n))))
            }
        }
        let digitA = aChars.first.map(index(of:)) ?? 0
        let digitB = b?.first.map(index(of:)) ?? digits.count
        if digitB - digitA > 1 {
            let mid = Int((0.5 * Double(digitA + digitB)).rounded())
            return String(digits[mid])
        }
        if let b, b.count > 1 { return String(b.prefix(1)) }
        return String(digits[digitA]) + (try midpoint(String(aChars.dropFirst()), nil))
    }
}
