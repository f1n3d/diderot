import SwiftUI
import DocmostKit

/// The user's active sessions; other devices can be signed out.
struct SessionsView: View {
    @Environment(AppSession.self) private var session
    @State private var state: LoadState<[UserSession]> = .idle
    @State private var isRevokingAll = false
    @State private var revokeError: String?

    var body: some View {
        AsyncContentView(state: state, retry: load) { sessions in
            List {
                Section {
                    ForEach(sessions) { item in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: item))
                                .font(.title3)
                                .foregroundStyle(item.isCurrent ? Color.accentColor : Color.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.displayName)
                                    if item.isCurrent {
                                        Text("This device")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    }
                                }
                                if let lastActive = item.lastActiveAt ?? item.createdAt {
                                    Text("Active \(lastActive, format: .relative(presentation: .named))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            if !item.isCurrent {
                                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    Task { await revoke(item) }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Swipe to sign out another device.")
                }
                if sessions.count > 1 {
                    Section {
                        Button("Sign Out All Other Devices", role: .destructive) {
                            Task { await revokeAll() }
                        }
                        .disabled(isRevokingAll)
                    }
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("Devices")
        .alert("Sign Out Failed", isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })) {
        } message: {
            Text(revokeError ?? "")
        }
        .task { if state.value == nil { await load() } }
    }

    private func icon(for item: UserSession) -> String {
        let name = item.displayName.lowercased()
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("mac") { return "laptopcomputer" }
        if name.contains("android") || name.contains("mobile") { return "smartphone" }
        return "desktopcomputer"
    }

    private func load() async {
        guard session.client != nil else { return }
        if state.value == nil { state = .loading }
        do {
            let list = try await session.send(Endpoints.Sessions.list)
            state = .loaded(list.sessions)
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) }
        }
    }

    private func revoke(_ item: UserSession) async {
        guard session.client != nil else { return }
        do {
            _ = try await session.send(Endpoints.Sessions.revoke(sessionId: item.id))
        } catch {
            revokeError = error.userMessage
        }
        await load()
    }

    private func revokeAll() async {
        guard session.client != nil else { return }
        isRevokingAll = true
        defer { isRevokingAll = false }
        do {
            _ = try await session.send(Endpoints.Sessions.revokeAll)
        } catch {
            revokeError = error.userMessage
        }
        await load()
    }
}
