import SwiftUI
import DocmostKit

/// Light/dark/system: stored locally, applied by the root view.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Toolbar workspace pill; its menu holds the workspace, account and server actions.
struct WorkspaceMenu: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @State private var showsSettings = false
    @State private var showsOpenLink = false

    var body: some View {
        Menu {
            if let ready = session.ready {
                Section(ready.currentUser.workspace.name) {
                    NavigationLink(value: HomeRoute.members) {
                        Label("Members", systemImage: "person.2")
                    }
                    Button("Workspace Settings", systemImage: "gearshape") {
                        openURL(ready.server.url.appending(path: "settings/workspace"))
                    }
                }
                Section(ready.currentUser.user.displayName) {
                    NavigationLink(value: HomeRoute.profile) {
                        Label("My Profile", systemImage: "person.crop.circle")
                    }
                    Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                    Button("Open Link…", systemImage: "link") { showsOpenLink = true }
                    Picker(selection: $appearance) {
                        ForEach(AppearanceSetting.allCases) { setting in
                            Text(setting.title).tag(setting)
                        }
                    } label: {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.menu)
                }
            }
            // Saved sign-ins, the current one checked.
            Section("Servers") {
                Picker("Server", selection: serverSelection) {
                    ForEach(session.accounts) { account in
                        Text(label(for: account)).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.inline)
                Button("Add Server…", systemImage: "plus") { session.beginAddingServer() }
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await session.signOut() }
            }
            .accessibilityIdentifier("sign-out")
        } label: {
            HStack(spacing: 6) {
                WorkspaceLogoView(size: 22)
                Text(session.ready?.currentUser.workspace.name ?? "Docmost")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Workspace menu")
        .accessibilityIdentifier("workspace-menu")
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsOpenLink) { OpenLinkSheet() }
    }

    private var serverSelection: Binding<String?> {
        Binding(
            get: { session.accounts.first(where: session.isCurrent)?.id },
            set: { id in
                guard let account = session.accounts.first(where: { $0.id == id }) else { return }
                Task { await session.switchTo(account) }
            }
        )
    }

    /// Workspace name, plus the host when several workspaces share the name.
    private func label(for account: StoredSession) -> String {
        let ambiguous = session.accounts.filter { $0.displayName == account.displayName }.count > 1
        return ambiguous ? "\(account.displayName) (\(account.host))" : account.displayName
    }
}

/// Workspace logo or initial.
struct WorkspaceLogoView: View {
    @Environment(AppSession.self) private var session
    var size: CGFloat = 24

    var body: some View {
        let workspace = session.ready?.currentUser.workspace
        RemoteThumbnail(url: session.server.flatMap { ImageURL.resolve(workspace?.logo, kind: .workspaceIcon, baseURL: $0.url) },
                        size: size, shape: RoundedRectangle(cornerRadius: size * 0.3)) { initial(workspace?.name ?? "D") }
    }

    private func initial(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: size * 0.3)
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The user's own profile (read-only; edits happen in the web client).
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let ready = session.ready {
            let user = ready.currentUser.user
            List {
                Section {
                    HStack(spacing: 16) {
                        AvatarView(name: user.displayName, avatarUrl: user.avatarUrl, baseURL: ready.server.url, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.displayName).font(.title3.weight(.semibold))
                            Text(user.email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    LabeledContent("Role", value: String(localized: user.workspaceRole.title))
                    LabeledContent("Workspace", value: ready.currentUser.workspace.name)
                    LabeledContent("Server", value: ready.server.url.host() ?? ready.server.url.absoluteString)
                }
                Section {
                    Button("Edit Profile on the Web", systemImage: "safari") {
                        openURL(ready.server.url.appending(path: "settings/account/profile"))
                    }
                }
            }
            .navigationTitle("My Profile")
            .toolbarTitleDisplayMode(.inline)
        }
    }
}

/// Workspace members (read-only).
struct WorkspaceMembersView: View {
    @Environment(AppSession.self) private var session
    @State private var state: LoadState<[WorkspaceMember]> = .idle
    @State private var query = ""

    var body: some View {
        AsyncContentView(state: state, retry: load) { members in
            let shown = filtered(members)
            List(shown) { member in
                HStack(spacing: 12) {
                    AvatarView(name: member.displayName, avatarUrl: member.avatarUrl, baseURL: session.server?.url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                        if let email = member.email {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let role = member.role {
                        Text(WorkspaceRole(rawValue: role).map { String(localized: $0.title) } ?? role.capitalized)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search members")
        }
        .navigationTitle("Members")
        .toolbarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
    }

    private func filtered(_ members: [WorkspaceMember]) -> [WorkspaceMember] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return members }
        return members.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle) || ($0.email?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state = .loading
        do {
            let members = try await Paginated.all { cursor in
                try await session.perform {
                    try await client.send(Endpoints.Workspace.members(PaginationOptions(limit: 100, cursor: cursor)))
                }
            }
            state = .loaded(members)
        } catch is CancellationError {
        } catch {
            state = .failed(error)
        }
    }
}

// MARK: - Role names

/// Role names as the web shows them.
extension WorkspaceRole {
    var title: LocalizedStringResource {
        switch self {
        case .owner: "Owner"
        case .admin: "Admin"
        case .member: "Member"
        }
    }
}

extension SpaceRole {
    var title: LocalizedStringResource {
        switch self {
        case .admin: "Full access"
        case .writer: "Can edit"
        case .reader: "Can view"
        }
    }
}
