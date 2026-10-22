import SwiftUI
import DocmostKit

/// Saved servers: switch, remove, add. Switching keeps the other sign-ins; cache and history are per server.
struct ServersView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

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
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await session.removeAccount(account) }
                            }
                        }
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
}
