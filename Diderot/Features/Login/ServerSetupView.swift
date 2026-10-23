import SwiftUI

/// First step: enter and verify the server address.
struct ServerSetupView: View {
    @Environment(AppSession.self) private var session
    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var warnsUnencrypted = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wiki.example.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit { connect() }
                        .accessibilityIdentifier("server-address")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your Docmost instance, for example https://wiki.example.com.")
                }

                FormErrorSection(message: errorMessage)

                Section {
                    Button(action: connect) {
                        BusyLabel(title: "Continue", isBusy: isConnecting)
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .accessibilityIdentifier("server-continue")
                }

                #if DEBUG
                Section("Development") {
                    Button("Use local dev server (localhost:3000)") {
                        address = "http://localhost:3000"
                        performConnect()
                    }
                }
                #endif
            }
            .navigationTitle("Diderot")
            .toolbar {
                // When adding another server, Cancel returns to the saved sign-in.
                if session.hasAccounts {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { Task { await session.cancelAddingServer() } }
                            .disabled(isConnecting)
                            .accessibilityIdentifier("server-cancel")
                    }
                }
            }
            .onAppear { isFocused = true }
            .alert("Unencrypted connection", isPresented: $warnsUnencrypted) {
                Button("Connect Anyway", role: .destructive) { performConnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This server uses HTTP: your password and your session travel over the network unencrypted. Only continue in a network you trust, such as your own.")
            }
        }
    }

    /// Plain HTTP (iOS allows it only in the local network) asks first: the password would travel readable.
    private func connect() {
        guard !isConnecting else { return }
        if ServerURLNormalizer.normalize(address)?.scheme == "http" {
            warnsUnencrypted = true
        } else {
            performConnect()
        }
    }

    private func performConnect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                try await session.connect(to: address)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
