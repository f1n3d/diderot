import SwiftUI
import DocmostKit

/// Home: recently opened pages and all spaces; bell and workspace menu in the toolbar. In the Search tab it is the
/// search backdrop: an active query replaces the content with results, like search in the space view.
struct HomeView: View {
    @Environment(NotificationsStore.self) private var notifications
    @Environment(SpacesStore.self) private var spaces
    @Environment(ReaderNavigation.self) private var navigation
    /// The Search tab's search; `nil` in the Spaces tab.
    var search: SearchModel?
    @State private var toast: String?
    @State private var showsNotifications = false
    @AppStorage("home.spacesGrid") private var showsGrid = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let search, search.isActive {
                    SearchResultsCard(search: search)
                } else {
                    RecentlyOpenedSection()
                    spacesSection
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                bell
            }
            ToolbarItem(placement: .topBarTrailing) {
                WorkspaceMenu()
            }
        }
        .refreshable {
            await spaces.load()
            await notifications.refreshUnreadCount()
        }
        .toast($toast)
        // MainTabView starts the first load; a failed one retries when Home reappears.
        .task { if case .failed = spaces.state { await spaces.load() } }
        #if DEBUG
        .task {
            // `DOCMOST_DEBUG_ROUTE=notifications`: open the popover once after launch (screenshots, UI tests).
            guard search == nil, DebugLaunch.route == "notifications", !Self.openedDebugNotifications else { return }
            Self.openedDebugNotifications = true
            try? await Task.sleep(for: .milliseconds(600))
            showsNotifications = true
        }
        #endif
    }

    #if DEBUG
    @MainActor private static var openedDebugNotifications = false
    #endif

    /// Bell with unread badge; opens notifications in a popover below it.
    private var bell: some View {
        Button {
            showsNotifications = true
        } label: {
            Label("Activity", systemImage: "bell")
        }
        .badge(notifications.unreadCount)
        .accessibilityIdentifier("home-activity")
        .accessibilityValue(notifications.unreadCount > 0 ? "\(notifications.unreadCount) unread" : "")
        .popover(isPresented: $showsNotifications) {
            NotificationsPopover { selection in
                showsNotifications = false
                navigation.open(selection)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your Spaces", systemImage: "folder.fill")
                    .font(.title3.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                if let count = spaces.state.value?.count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                Picker("Layout", selection: $showsGrid) {
                    Image(systemName: "rectangle.grid.1x2").tag(false)
                    Image(systemName: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
                .accessibilityLabel("Layout")
            }
            switch spaces.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).padding()
            case .failed(let error):
                ErrorStateView(error: error) { await spaces.load() }
            case .loaded(let items):
                if items.isEmpty {
                    Text("You are not a member of any space yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else if showsGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(items) { space in
                            NavigationLink(value: space) {
                                SpaceGridCard(space: space)
                            }
                            .buttonStyle(.plain)
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .contextMenu { SpaceActions(space: space, toast: $toast) }
                            .accessibilityIdentifier("space-tile-\(space.slug)")
                        }
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { space in
                            SpaceCard(space: space, toast: $toast)
                        }
                    }
                }
            }
        }
    }
}

/// Space actions: in the list card's "…" menu and via long press on card and grid tile.
private struct SpaceActions: View {
    @Environment(AppSession.self) private var session
    @Environment(FavoritesStore.self) private var favorites
    let space: Space
    @Binding var toast: String?

    var body: some View {
        let isFavorite = favorites.isFavorite(spaceId: space.id)
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star") {
            Task { await favorites.toggleSpace(space.id) }
        }
        if let url = session.server?.url.appending(path: "s/\(space.slug)") {
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.url = url
                toast = String(localized: "Link copied")
            }
        }
    }
}

/// Space card with icon, name, description and menu.
private struct SpaceCard: View {
    @Environment(AppSession.self) private var session
    let space: Space
    @Binding var toast: String?

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: space) {
                HStack(spacing: 14) {
                    SpaceLogoView(space: space, baseURL: session.server?.url, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(space.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(space.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("space-\(space.slug)")
            Menu {
                SpaceActions(space: space, toast: $toast)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu { SpaceActions(space: space, toast: $toast) }
    }
}

private struct SpaceGridCard: View {
    @Environment(AppSession.self) private var session
    let space: Space

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpaceLogoView(space: space, baseURL: session.server?.url, size: 44)
            Text(space.name)
                .font(.headline)
                .lineLimit(2)
            Text(space.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private extension Space {
    var subtitle: String {
        if let description, !description.isEmpty { return description }
        if let role { return String(localized: role.title) }
        return String(localized: "Space")
    }
}

/// "Recently Opened": horizontal cards from the local history; "All" leads to the recently updated pages.
private struct RecentlyOpenedSection: View {
    @Environment(RecentlyOpenedStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recently Opened", systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink(value: HomeRoute.recent) {
                    HStack(spacing: 2) {
                        Text("All")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            if store.items.isEmpty {
                Text("Pages you open will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(store.items) { item in
                            NavigationLink(value: PageSelection(pageId: item.id, title: item.title)) {
                                RecentCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }
}

private struct RecentCard: View {
    let item: RecentlyOpenedStore.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                PageIconView(icon: item.icon, size: 26, isBase: item.isBase == true)
                    .padding(6)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                if let space = item.spaceName {
                    Text(space)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(item.openedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 200, height: 150, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
