import SwiftUI
import DocmostKit

/// Saved servers: switch, remove, add. Switching keeps the other sign-ins; cache and history are per server.
struct ServersView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// The server whose removal waits for the confirmation.
    @State private var removing: StoredSession?

    var body: some View {
        List {
            Section {
                ForEach(session.accounts) { account in
                    let isCurrent = session.isCurrent(account)
                    Button {
                        guard !isCurrent else { return }
                        Task { await session.switchTo(account) }
                    } label: {
                        HStack(spacing: 12) {
                            // Explicit colors, or the button tints the row with the accent color.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName)
                                    .foregroundStyle(Color.primary)
                                Text(account.host)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                if let email = account.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                            Spacer()
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Current")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("server-\(account.host)")
                    .swipeActions(edge: .trailing) {
                        if !isCurrent {
                            // Not `.destructive`: that role slides the row out at once, with a dialog attached to it.
                            Button("Remove", systemImage: "trash") { remove(account) }
                                .tint(.red)
                        }
                    }
                    // Removing deletes changes that wait for the server; a full swipe deleted them without a word.
                    .confirmationDialog(Text("Remove “\(account.displayName)”?"),
                                        isPresented: Binding { removing?.id == account.id } set: { if !$0 { removing = nil } },
                                        titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { Task { await session.removeAccount(account) } }
                    } message: {
                        Text("Changes you made on this server haven't reached it yet. Removing the server deletes them from this device.")
                    }
                }
            } footer: {
                Text("Switching keeps you signed in on the other servers. Swipe to remove a server.")
            }
            Section {
                Button("Add Server…", systemImage: "plus") {
                    dismiss()
                    session.beginAddingServer()
                }
                .accessibilityIdentifier("add-server")
            }
        }
        .navigationTitle("Servers")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Asks first only while changes wait for the server; otherwise it goes at once, as before.
    private func remove(_ account: StoredSession) {
        if UnsentChanges.hasEntries(server: account.serverURL) {
            removing = account
        } else {
            Task { await session.removeAccount(account) }
        }
    }
}
