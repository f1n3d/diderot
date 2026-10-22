import Foundation

/// Shared JSON coding. Dates are ISO 8601 with milliseconds; decoding also accepts them without fractional seconds.
enum JSONDecoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
            }
            return date
        }
        return decoder
    }

    /// Matches the server's `toISOString()`.
    static let fullDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fullDateStyle))
        }
        return encoder
    }

    static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: fullDateStyle) {
            return date
        }
        if let date = try? Date(raw, strategy: .iso8601) {
            return date
        }
        return nil
    }
}
