import Foundation

/// A page's verification (`pages/verification-info`, license feature `page:verification`): verified for a time
/// ("expiring") or approved in a review ("qms"). Docmost 0.98 takes it back with any edit or rename of a page in one of
/// the locked states, so its web client opens such a page read-only and asks before editing
/// (`ee/page-verification/page-verification.constants.ts`, `use-page-edit-mode.tsx`).
public struct PageVerification: Codable, Sendable, Hashable {
    /// What editing would take back, by the web's dialogs. Every other status (`none`, `draft`, `invalidated`,
    /// `expired`, `obsolete`, one a newer server adds) edits without asking.
    public enum Lock: String, Codable, Sendable, Hashable {
        /// `verified`, and `expiring` (shown as "Review needed").
        case verified
        case approved
        case inApproval
    }

    /// `verified`, `expiring`, `expired`, `invalidated`, `draft`, `in_approval`, `approved`, `obsolete` or `none`.
    public let status: String

    public init(status: String) {
        self.status = status
    }

    public var lock: Lock? {
        switch status {
        case "verified", "expiring": .verified
        case "approved": .approved
        case "in_approval": .inApproval
        default: nil
        }
    }
}
