import SwiftUI
import DocmostKit

/// A person's profile on a tab's stack (Docmost 0.98): from a user mention on a page or in its comments, and from the
/// workspace's members.
struct UserProfileRoute: Hashable {
    let userId: String
    /// What the members list showed, as the title until the profile has loaded.
    var name: String?
}

/// A person's profile as the web's profile page shows it (`user-profile-page.tsx`): avatar, name, role, whether they
/// were deactivated or deleted, email, then the pages they created or edited last and the spaces both people share.
/// The web's "Copy link", "Edit profile" and "Manage user" stay there.
struct UserProfileView: View {
    @Environment(AppSession.self) private var session
    let route: UserProfileRoute
    @State private var model: UserProfileModel?

    var body: some View {
        Group {
            if let model, model.isNotFound {
                ContentUnavailableView {
                    Label("Profile not found", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("This profile doesn't exist or isn't available to you.")
                }
                .accessibilityIdentifier("profile-not-found")
            } else {
                AsyncContentView(state: model?.profile ?? .idle, retry: { await model?.load() }) { profile in
                    if let model {
                        List {
                            Section { ProfileHeader(profile: profile) }
                            ProfileActivitySections(model: model)
                        }
                        .refreshable { await model.load() }
                    }
                }
            }
        }
        .navigationTitle(model?.profile.value?.displayName ?? route.name ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toast(Binding { model?.toast } set: { model?.toast = $0 })
        // Again on each return: a load that leaving the screen cancelled (a page opened from here) starts over.
        .task(id: route.userId) {
            let model = model ?? UserProfileModel(userId: route.userId, session: session)
            self.model = model
            await model.loadIfNeeded()
        }
    }
}

/// Avatar, name, role and status, email: the web's `UserProfileHeader` without its buttons.
private struct ProfileHeader: View {
    @Environment(AppSession.self) private var session
    let profile: UserProfile

    var body: some View {
        HStack(spacing: 16) {
            AvatarView(name: profile.displayName, avatarUrl: profile.avatarUrl, baseURL: session.server?.url, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.displayName).font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    if let role = profile.role { RoleBadge(role: role) }
                    // Deleted before deactivated, as on the web: a deleted person can have been deactivated first.
                    if profile.deletedAt != nil {
                        AccountStatusBadge(text: "Deleted", color: .red)
                    } else if profile.deactivatedAt != nil {
                        AccountStatusBadge(text: "Deactivated", color: .orange)
                    }
                }
                if let email = profile.email, !email.isEmpty {
                    Text(email).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-header")
    }
}

/// Beside the role, in the web's colors.
private struct AccountStatusBadge: View {
    let text: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// The pages a person created or edited last and the spaces both people share, ten at a time with "Load More", as the
/// web's `UserProfileOverview`; on the own profile too. Pages and spaces open on the stack.
struct ProfileActivitySections: View {
    @Environment(AppSession.self) private var session
    let model: UserProfileModel

    var body: some View {
        Section("Recent Pages") {
            rows(model.recentPages, more: "profile-pages-more") { page in
                NavigationLink(value: PageSelection(pageId: page.id, title: page.title)) {
                    RecentPageRow(page: page)
                }
                .accessibilityIdentifier("profile-page-\(page.id)")
            } empty: {
                if model.isSelf {
                    EmptyRow(title: "No recent pages", detail: "Pages you create or edit will show up here.")
                } else {
                    EmptyRow(title: "No recent pages", detail: "Pages they create or edit in your spaces will show up here.")
                }
            }
        }
        Section("Spaces") {
            rows(model.spaces, more: "profile-spaces-more") { space in
                NavigationLink(value: SpaceRoute(spaceId: space.id)) {
                    HStack(spacing: 10) {
                        SpaceLogoView(name: space.displayName, logo: space.logo, baseURL: session.server?.url, size: 28)
                        Text(space.displayName)
                    }
                }
                .accessibilityIdentifier("profile-space-\(space.slug ?? space.id)")
            } empty: {
                if model.isSelf {
                    EmptyRow(title: "No spaces yet", detail: "Spaces you join will show up here.")
                } else {
                    EmptyRow(title: "No shared spaces", detail: "You don't share any spaces.")
                }
            }
        }
    }

    /// A list's rows by its state: a spinner, the error with "Try Again", what it says when empty, or the items with
    /// "Load More" while more follow.
    @ViewBuilder
    private func rows<Item, Row: View, Empty: View>(_ list: ProfileListing<Item>, more identifier: String,
                                                    @ViewBuilder row: @escaping (Item) -> Row,
                                                    @ViewBuilder empty: () -> Empty) -> some View {
        switch list.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity)
        case .failed(let error):
            FailedRow(error: error) { await model.reload(list) }
        case .loaded(let items):
            if items.isEmpty { empty() }
            ForEach(items, content: row)
            if list.hasMore {
                Button {
                    Task { await model.loadMore(list) }
                } label: {
                    HStack {
                        Text("Load More")
                        Spacer()
                        if list.isLoadingMore { ProgressView() }
                    }
                }
                .disabled(list.isLoadingMore)
                .accessibilityIdentifier(identifier)
            }
        }
    }
}

/// A recent page as Recently Updated shows one, with what the person did when (the web's "Edited …" / "Created …").
private struct RecentPageRow: View {
    let page: UserRecentPage

    var body: some View {
        HStack(spacing: 10) {
            PageIconView(icon: page.icon, size: 22, isBase: page.isBase == true)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.displayTitle)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let space = page.space?.displayName, !space.isEmpty {
                        Text(space)
                        if page.activityAt != nil { Text("·") }
                    }
                    if let activityAt = page.activityAt {
                        if page.wasEdited {
                            Text("Edited \(activityAt, format: .relative(presentation: .named))")
                        } else {
                            Text("Created \(activityAt, format: .relative(presentation: .named))")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// What an empty list says, as the web's empty states.
private struct EmptyRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A list whose first page failed, as the web's "Something went wrong" with "Try again".
private struct FailedRow: View {
    let error: any Error
    let retry: () async -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Something went wrong").font(.subheadline.weight(.medium))
                Text(error.userMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Try Again") { Task { await retry() } }
                .buttonStyle(.bordered)
        }
    }
}
