import Foundation

/// Arbitrary JSON value for schemaless fields such as `attrs` in page content or `settings`.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// The deepest a value decodes, counted in the values around it; deeper ones decode as `.null`. Decoding goes a level
    /// deeper in the stack per level, and a page as deep as JSONDecoder takes (512 levels) ran out of a thread's and
    /// ended the app on every open (code review R35). Pages nest about 20 levels; the parser shows nodes down to
    /// `ContentParser.maxDepth` and a note for the next, 67 levels (two per node).
    static let maxDepth = 100

    /// How many values the decoding on this thread is inside: a decoding runs on one thread from start to end.
    private static var decodingDepth: Int {
        get { Int(bitPattern: pthread_getspecific(depthKey)) }
        set { pthread_setspecific(depthKey, UnsafeRawPointer(bitPattern: newValue)) }
    }

    private static let depthKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    public init(from decoder: Decoder) throws {
        let depth = Self.decodingDepth
        guard depth < Self.maxDepth else {
            self = .null
            return
        }
        Self.decodingDepth = depth + 1
        defer { Self.decodingDepth = depth }
        let container = try decoder.singleValueContainer()
        // Most likely types first: each failed probe throws, and JSONDecoder never converts between these types.
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a valid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Accessors

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard let value = doubleValue, value.rounded() == value, abs(value) < Double(Int.max) else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
