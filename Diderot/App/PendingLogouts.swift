import Foundation
import DocmostKit

/// Sign-outs their server didn't get, out of reach then: kept in the Keychain (`SessionStore.pendingLogouts`) and sent
/// at launch, back in the app and when the network returns (`AppSession.sendPendingLogouts`). Out of reach, a session
/// would stay valid on its server until it expires.
@MainActor
final class PendingLogouts {
    /// Expired longer than a clock runs ahead, and its server out of reach meanwhile.
    private static let expiredLongAgo: TimeInterval = 7 * 24 * 3600

    private let store: SessionStore
    /// A client for a server, with a token.
    private let client: (URL, String) -> APIClient
    private var isSending = false

    init(store: SessionStore, client: @escaping (URL, String) -> APIClient) {
        self.store = store
        self.client = client
    }

    /// Keeps the sign-out of `session` until its server answers.
    func keep(_ session: StoredSession) throws {
        var pending = try store.pendingLogouts()
        pending.removeAll { StoredAccounts.key(for: $0.serverURL) == StoredAccounts.key(for: session.serverURL) && $0.token == session.token }
        pending.append(session)
        try store.setPendingLogouts(pending)
    }

    /// Ends the kept sessions on their servers. A token the server no longer knows (401), or that expired a week ago, is
    /// dropped; one whose server is still out of reach stays. Throws when the Keychain couldn't be updated.
    func send() async throws {
        guard !isSending, let pending = try? store.pendingLogouts(), !pending.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        var done: [StoredSession] = []
        for entry in pending {
            // The server judges a token that just expired: by the device's clock, which can run ahead, sign-outs were
            // dropped whose sessions the server still took (code review R30).
            if let expiresAt = entry.claims?.expiresAt, expiresAt < .now - Self.expiredLongAgo {
                done.append(entry)
                continue
            }
            do {
                _ = try await client(entry.serverURL, entry.token).send(Endpoints.Auth.logout)
                done.append(entry)
            } catch let error as APIError where error.isSessionExpired {
                done.append(entry)
            } catch {
                AppLog.session.notice("Sign-out still waits for its server: \(error.userMessage, privacy: .public)")
            }
        }
        // Read again: a sign-out meanwhile added its own.
        try store.setPendingLogouts(try store.pendingLogouts().filter { !done.contains($0) })
    }
}
