import Foundation

extension Endpoints.Users {
    public struct TimeZoneBody: Encodable, Sendable {
        public let timezone: String

        public init(timezone: String) {
            self.timezone = timezone
        }
    }

    /// Sets the signed-in user's time zone (an IANA name, Docmost 0.98; older servers refuse the field).
    public static func update(timezone: String) -> Endpoint<NoContent> {
        .post("users/update", body: TimeZoneBody(timezone: timezone))
    }
}
