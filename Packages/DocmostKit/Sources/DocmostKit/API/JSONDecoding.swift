import Foundation

/// Shared JSON coding. Dates are ISO 8601 with milliseconds; decoding also accepts them without fractional seconds.
enum JSONDecoding {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = Date(docmostISO: raw) else {
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
}

public extension Date {
    /// An ISO 8601 instant as Docmost writes it, with milliseconds (`toISOString()`), else without fractional seconds;
    /// in UTC or with an offset. Public so that the dates the app reads from JSON it decodes itself (a database cell, a
    /// link preview's metadata) parse as the API's do.
    init?(docmostISO text: String) {
        guard let date = (try? Date(text, strategy: JSONDecoding.fullDateStyle))
                ?? (try? Date(text, strategy: .iso8601)) else { return nil }
        self = date
    }
}
