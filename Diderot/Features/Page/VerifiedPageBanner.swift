import SwiftUI
import DocmostKit

/// A verified or approved page (Docmost's page verification, license feature `page:verification`) shows read-only with
/// this notice until the person chooses to edit it: on Docmost 0.98 any edit or rename takes the verification or approval
/// back, as the web's dialog says before it unlocks the page (`use-page-edit-mode.tsx`). Comments still work.
struct VerifiedPageBanner: View {
    let verification: PageVerification
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(VerifiedPage.status(of: verification), systemImage: "checkmark.seal")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Button("Edit", action: edit)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("page-verification-edit")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-verification")
    }
}

/// A page whose verification the server didn't say since it opened (license feature `page:verification`): editing waits
/// for an answer, as on the web, where the editor says so with "Try again" (`full-editor.tsx`). An edit could take a
/// verification back that the app doesn't know of.
struct VerificationPausedBanner: View {
    let retrying: Bool
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Editing is paused because the page verification status could not be checked.", systemImage: "pause.circle")
                .font(.subheadline)
            Spacer(minLength: 0)
            if retrying {
                ProgressView()
            } else {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("page-verification-retry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-verification-paused")
    }
}

/// The texts of a verified page, the web's (`verification-status.ts`, `use-page-edit-mode.tsx`).
enum VerifiedPage {
    /// What "Edit" on a locked page was asked for: the page's text and title, or a note appended to it.
    struct Ask: Equatable, Identifiable {
        enum Then: Equatable { case edit, appendNote }

        let lock: PageVerification.Lock
        let then: Then

        var id: String { "\(lock)-\(then)" }
    }

    /// Whether a held connect (`EngineHold`) asks the server for the page's verification before its changes go: a
    /// reconnect always (the page may have been verified again meanwhile), the first connect unless the last answer is
    /// under 5 s old, as the web counts one that recent for a page being opened.
    static func asksFirst(_ hold: EngineHold, answeredAt: Date?, now: Date = .now) -> Bool {
        hold.connect > 1 || answeredAt.map { now.timeIntervalSince($0) > 5 } ?? true
    }

    static func status(of verification: PageVerification) -> String {
        switch verification.status {
        case "expiring": String(localized: "Review needed")
        case "approved": String(localized: "Approved")
        case "in_approval": String(localized: "In approval")
        default: String(localized: "Verified")
        }
    }

    static func title(_ lock: PageVerification.Lock) -> String {
        switch lock {
        case .verified: String(localized: "Edit verified page?")
        case .approved: String(localized: "Edit approved page?")
        case .inApproval: String(localized: "Edit page in approval?")
        }
    }

    static func message(_ lock: PageVerification.Lock) -> String {
        switch lock {
        case .verified: String(localized: "Changes remove the verification until a verifier verifies the page again.")
        case .approved: String(localized: "Changes return this page to draft. It has to be approved again.")
        case .inApproval: String(localized: "Changes withdraw the approval request and return this page to draft.")
        }
    }
}
