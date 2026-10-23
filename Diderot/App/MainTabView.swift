import SwiftUI
import DocmostKit

enum AppTab: String, Hashable {
    case spaces, search, favorites
}

/// Main view after sign-in: tab bar (sidebar on iPad), one navigation stack per tab. Pages push in the active tab, deep
/// links in Spaces. Notifications open from Home's bell; the Search tab is Home with the search field in the tab bar.
struct MainTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .spaces
    @State private var spacesNavigation = ReaderNavigation()
    @State private var searchNavigation = ReaderNavigation()
    @State private var favoritesNavigation = ReaderNavigation()
    @State private var favorites: FavoritesStore
    @State private var notifications: NotificationsStore
    @State private var spaces: SpacesStore
    @State private var recentlyOpened: RecentlyOpenedStore
    @State private var changes = ContentChanges()
    @State private var offline = OfflineMonitor()

    init(session: AppSession) {
        self._favorites = State(initialValue: FavoritesStore(session: session))
        self._notifications = State(initialValue: NotificationsStore(session: session))
        self._spaces = State(initialValue: SpacesStore(session: session))
        self._recentlyOpened = State(initialValue: RecentlyOpenedStore(cache: session.ready?.cache))
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Spaces", systemImage: "square.grid.2x2", value: AppTab.spaces) {
                tabStack(spacesNavigation) { HomeView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                tabStack(searchNavigation) { HomeSearchView() }
            }
            Tab("Favorites", systemImage: "star", value: AppTab.favorites) {
                tabStack(favoritesNavigation) { FavoritesView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // The Search tab opens its search field with the keyboard right away.
        .tabViewSearchActivation(.searchTabSelection)
        .environment(favorites)
        .environment(notifications)
        .environment(spaces)
        .environment(recentlyOpened)
        .environment(changes)
        .environment(offline)
        // Above the floating tab bar, in its style; pages (no tab bar on iPhone) show their own status.
        .tabViewBottomAccessory(isEnabled: offline.isOffline || session.ready?.restoredOffline == true) {
            OfflineNotice(isOffline: offline.isOffline)
        }
        .onChange(of: offline.isOffline) { _, isOffline in
            guard !isOffline else { return }
            Task {
                await session.reconnectIfNeeded()
                await sendUnsentTitles()
            }
        }
        .onChange(of: appNavigation.pendingSelection, initial: true) { _, pending in
            guard let pending else { return }
            tab = .spaces
            spacesNavigation.open(pending)
            appNavigation.pendingSelection = nil
        }
        // Polls while the scene is active; SwiftUI cancels it when a server switch or sign-out removes the view.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Page titles kept while the server was away go out once it may be back: here (app active, or this view new
            // after a sign-in or switch) and when the network returns (above).
            await sendUnsentTitles()
            while !Task.isCancelled {
                await notifications.refreshUnreadCount()
                try? await Task.sleep(for: NotificationsStore.pollInterval)
            }
        }
        .task {
            await recentlyOpened.load()
            await favorites.loadIds()
            await applyDebugLaunch()
        }
        // Here, not in HomeView: a tab switch or a page opened at launch hides Home and would cancel the first load.
        .task { await spaces.loadIfNeeded() }
    }

    private func sendUnsentTitles() async {
        for spaceId in await session.sendUnsentTitles() { changes.pageChanged(in: spaceId) }
    }

    /// A tab's navigation stack with every destination reachable from any view.
    private func tabStack<Root: View>(_ navigation: ReaderNavigation, @ViewBuilder root: () -> Root) -> some View {
        @Bindable var navigation = navigation
        return NavigationStack(path: $navigation.path) {
            root()
                .navigationDestination(for: PageSelection.self) { selection in
                    PageView(selection: selection)
                }
                .navigationDestination(for: Space.self) { space in
                    SpaceView(space: space)
                }
                .navigationDestination(for: SpaceRoute.self) { route in
                    SpaceRouteView(route: route)
                }
                .navigationDestination(for: SpaceTrashRoute.self) { route in
                    TrashView(route: route)
                }
                .navigationDestination(for: HomeRoute.self) { route in
                    switch route {
                    case .recent: RecentPagesView()
                    case .members: WorkspaceMembersView()
                    case .profile: ProfileView()
                    }
                }
        }
        .environment(navigation)
    }

    /// Debug builds: jump to a space, page or tab (screenshots, UI tests).
    private func applyDebugLaunch() async {
        guard let ready = session.ready else { return }
        if let spaceId = DebugLaunch.spaceId {
            if let space = try? await ready.client.send(Endpoints.Spaces.info(spaceId: spaceId)) {
                spacesNavigation.path.append(space)
            } else if let cached = await ready.cache.read([Space].self, key: CacheKey.spaces)?
                        .first(where: { $0.id == spaceId || $0.slug == spaceId })
            {
                spacesNavigation.path.append(cached)
            }
        }
        switch DebugLaunch.route {
        case "search": tab = .search
        case "favorites": tab = .favorites
        case "recent": spacesNavigation.path.append(HomeRoute.recent)
        default: break
        }
        if let pageId = DebugLaunch.pageId {
            spacesNavigation.open(PageSelection(pageId: pageId))
        }
    }
}

/// Destinations of every tab's stack that have no model of their own.
enum HomeRoute: Hashable {
    case recent, members, profile
}

/// Offline notice in the tab bar accessory; short while the scrolled-down tab bar shows it beside its button.
private struct OfflineNotice: View {
    let isOffline: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(.orange)
        }
        .font(.footnote.weight(.medium))
        .accessibilityAddTraits(.isStaticText)
    }

    private var text: LocalizedStringKey {
        if placement == .inline { return isOffline ? "Offline" : "Server unreachable" }
        return isOffline ? "Offline – showing saved content" : "Server unreachable – showing saved content"
    }
}
