import SwiftUI
import DocmostKit

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    /// Link that arrived while the app couldn't open it (`AppSession.opensLinks`), e.g. the launch link before the
    /// server is known.
    @State private var queuedURL: URL?

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                LaunchView()
            case .noServer:
                ServerSetupView()
            case .signedOut(let server), .authenticating(let server):
                // A fresh form per server: switching to an expired sign-in never shows `.restoring` in between.
                LoginView(server: server)
                    .id(StoredAccounts.key(for: server.url))
            case .ready(let ready):
                // A fresh main view per server (own stores, navigation stacks, cache).
                MainTabView(session: session)
                    .id(StoredAccounts.key(for: ready.server.url))
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await session.restoreAtLaunch()
            await session.sendPendingLogouts()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await session.refreshCurrentUser()
                await session.sendPendingLogouts()
            }
        }
        .onOpenURL { url in
            // `diderot://open?url=…`; the selection is applied once the main view exists.
            if session.opensLinks { open(url) } else { queuedURL = url }
        }
        .onChange(of: session.opensLinks) { _, opens in
            guard opens, let url = queuedURL else { return }
            queuedURL = nil
            open(url)
        }
    }

    private func open(_ url: URL) {
        if appNavigation.handle(url, session: session) { return }
        // Private: links can carry invitation or password-reset tokens, and logs can be exported.
        AppLog.ui.notice("Ignored URL: \(url.absoluteString, privacy: .private)")
    }
}

/// While the saved sign-in is restored: the app icon and name; a spinner only once it takes a moment.
private struct LaunchView: View {
    @State private var showsProgress = false

    var body: some View {
        VStack(spacing: 16) {
            Image("AppLogo")
                .resizable()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(.separator, lineWidth: 0.5))
                .accessibilityHidden(true)
            Text(verbatim: "Diderot")
                .font(.title2.weight(.semibold))
            ProgressView()
                .opacity(showsProgress ? 1 : 0)
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            withAnimation { showsProgress = true }
        }
    }
}
