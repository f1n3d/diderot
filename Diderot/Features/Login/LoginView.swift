import SwiftUI
import DocmostKit

/// Sign-in: password and LDAP natively, SSO in the embedded browser, MFA as a second step.
struct LoginView: View {
    @Environment(AppSession.self) private var session
    let server: ServerInfo

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var browserLoginURL: URL?
    @State private var mfaChallenge: MFAChallenge?
    @State private var ldapProvider: AuthProvider?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var isAuthenticating: Bool {
        if case .authenticating = session.state { return true }
        return false
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isAuthenticating
    }

    private var providers: [AuthProvider] { server.workspace?.providers ?? [] }
    private var requiresSso: Bool { server.workspace?.requiresSso == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    WorkspaceHeader(server: server)
                } footer: {
                    if server.url.scheme == "http" {
                        Label("Unencrypted connection: your password and your session travel unprotected.", systemImage: "lock.open")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("login-unencrypted")
                    }
                }

                if !requiresSso {
                    passwordSection
                }

                if !providers.isEmpty {
                    Section("Single sign-on") {
                        ForEach(providers) { provider in
                            Button {
                                if provider.isLDAP {
                                    ldapProvider = provider
                                } else {
                                    browserLoginURL = Endpoints.SSO.browserLoginURL(server: server.url, provider: provider, workspaceId: server.workspace?.id)
                                }
                            } label: {
                                Label("Continue with \(provider.name)", systemImage: provider.isLDAP ? "person.text.rectangle" : "building.2")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        browserLoginURL = server.url.appending(path: "login")
                    } label: {
                        Label("Sign in in Browser", systemImage: "safari")
                    }
                } footer: {
                    Text(requiresSso
                         ? "This workspace requires single sign-on. The browser sign-in handles it, including two-factor authentication."
                         : "Use the browser sign-in if your account uses single sign-on or two-factor authentication.")
                }
            }
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Change Server") { session.beginAddingServer() }
                        .disabled(isAuthenticating)
                }
            }
            .onAppear {
                if DebugLaunch.browserLogin {
                    browserLoginURL = server.url.appending(path: "login")
                } else if !requiresSso {
                    focusedField = .email
                }
            }
            // A restored sign-in has no workspace info (SSO, providers, logo) yet; retries after a failed sign-in.
            .task(id: isAuthenticating) { await session.loadWorkspaceInfo() }
            .sheet(item: $browserLoginURL) { url in
                BrowserLoginView(server: server, startURL: url)
            }
            .sheet(item: $mfaChallenge) { challenge in
                MFACodeView(challenge: challenge)
            }
            .sheet(item: $ldapProvider) { provider in
                LDAPLoginView(provider: provider)
            }
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        Section("Sign in") {
            TextField("Email", text: $email)
                .accessibilityIdentifier("login-email")
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .email)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
            SecureField("Password", text: $password)
                .accessibilityIdentifier("login-password")
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit(submit)
        }

        FormErrorSection(message: errorMessage)

        Section {
            Button(action: submit) {
                BusyLabel(title: "Sign In", isBusy: isAuthenticating)
            }
            .disabled(!canSubmit)
            .accessibilityIdentifier("login-submit")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        Task {
            do {
                let outcome = try await session.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                if case .mfaRequired(let challenge) = outcome {
                    if challenge.needsSetup {
                        errorMessage = AppSessionError.mfaSetupRequired.localizedDescription
                    } else {
                        mfaChallenge = challenge
                    }
                }
            } catch {
                errorMessage = error.userMessage
                password = ""
                focusedField = .password
            }
        }
    }
}

extension MFAChallenge: @retroactive Identifiable {
    public var id: String { mfaToken ?? "mfa" }
}

/// Second sign-in step: a 6-digit authenticator code or an 8-digit backup code.
struct MFACodeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let challenge: MFAChallenge
    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isVerifying = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($isFocused)
                        .onSubmit(verify)
                } header: {
                    Text("Two-factor authentication")
                } footer: {
                    Text("Enter the 6-digit code from your authenticator app or one of your backup codes. The code must be entered within five minutes.")
                }
                FormErrorSection(message: errorMessage)
                Section {
                    Button(action: verify) {
                        BusyLabel(title: "Verify", isBusy: isVerifying)
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || isVerifying)
                }
            }
            .navigationTitle("Verify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { isFocused = true }
        }
        .interactiveDismissDisabled(isVerifying)
    }

    private func verify() {
        guard !isVerifying else { return }
        isVerifying = true
        errorMessage = nil
        Task {
            defer { isVerifying = false }
            do {
                try await session.completeMFA(challenge, code: code)
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// LDAP sign-in with username and password (Enterprise).
struct LDAPLoginView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let provider: AuthProvider
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var mfaChallenge: MFAChallenge?

    var body: some View {
        NavigationStack {
            Form {
                Section(provider.name) {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(submit)
                }
                FormErrorSection(message: errorMessage)
                Section {
                    Button(action: submit) {
                        BusyLabel(title: "Sign In", isBusy: isSubmitting)
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $mfaChallenge) { challenge in
                MFACodeView(challenge: challenge)
            }
        }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                let outcome = try await session.signInWithLDAP(providerId: provider.id, username: username, password: password)
                switch outcome {
                case .signedIn: dismiss()
                case .mfaRequired(let challenge):
                    if challenge.needsSetup {
                        errorMessage = AppSessionError.mfaSetupRequired.localizedDescription
                    } else {
                        mfaChallenge = challenge
                    }
                }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// Workspace name and logo, with the server address below.
struct WorkspaceHeader: View {
    let server: ServerInfo

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumbnail(url: ImageURL.resolve(server.workspace?.logo, kind: .workspaceIcon, baseURL: server.url), size: 44,
                            shape: RoundedRectangle(cornerRadius: 10)) { placeholder }
            VStack(alignment: .leading) {
                Text(server.displayName)
                    .font(.headline)
                Text(server.url.host() ?? server.url.absoluteString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.tint.opacity(0.15))
            .frame(width: 44, height: 44)
            .overlay {
                Text(String(server.displayName.prefix(1)).uppercased())
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
            }
    }
}
