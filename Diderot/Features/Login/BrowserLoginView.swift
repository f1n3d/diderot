import SwiftUI
import WebKit
import DocmostKit

/// Sign-in via the embedded browser: Docmost web sign-in, SSO redirects and MFA run in the web UI. Once the HttpOnly
/// cookie `authToken` (type `access`) appears in the cookie store, the app adopts it and discards the store.
struct BrowserLoginView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let server: ServerInfo
    let startURL: URL

    /// Made once: built in `init`, a page and its store came anew on every pass of the sign-in screen while this showed.
    @State private var parts = Once<(dataStore: WKWebsiteDataStore, page: WebPage)>()
    @State private var errorMessage: String?
    @State private var isFinishing = false
    @State private var captured = false

    init(server: ServerInfo, startURL: URL) {
        self.server = server
        self.startURL = startURL
    }

    private var browser: (dataStore: WKWebsiteDataStore, page: WebPage) {
        parts {
            let dataStore = WKWebsiteDataStore.nonPersistent()
            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = dataStore
            return (dataStore, WebPage(configuration: configuration))
        }
    }

    private var dataStore: WKWebsiteDataStore { browser.dataStore }
    private var page: WebPage { browser.page }

    var body: some View {
        NavigationStack {
            WebView(page)
                .overlay {
                    if isFinishing {
                        ZStack {
                            Color(.systemBackground).opacity(0.8)
                            ProgressView("Signing in…")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
                }
                // The host of the page asking for the password, not a name the server picks: a hostile server could
                // show a copy of an identity provider's sign-in page under its workspace name.
                .navigationTitle(page.url?.host() ?? server.url.host() ?? server.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Not once the token is taken: the sign-in finishes, or fails and ends its session on the server.
                        Button("Cancel") { dismiss() }
                            .disabled(isFinishing)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                    }
                }
                .task { await run() }
        }
        .interactiveDismissDisabled(isFinishing)
    }

    private func run() async {
        page.load(URLRequest(url: startURL))
        #if DEBUG
        var debugLoginTriggered = false
        var settledTicks = 0
        #endif
        // Poll cookies, not navigation events: the end of an SSO redirect chain doesn't reliably surface as an event.
        while !Task.isCancelled && !captured {
            if await checkForToken() { break }
            #if DEBUG
            // The web client redirects once more after the first load; only step in after two quiet seconds.
            settledTicks = page.isLoading ? 0 : settledTicks + 1
            if !debugLoginTriggered, DebugLaunch.browserLogin, settledTicks >= 2 {
                debugLoginTriggered = true
                await runDebugAutoLoginIfRequested()
            }
            #endif
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The access token the server set after a sign-in in `cookies`: as Docmost sets it, HttpOnly and for its host only
    /// (no `Domain`). By name and domain alone, a sibling subdomain's cookie for the parent domain also counted, and
    /// signed the app in to whatever account that one was for (code review R12). `Secure` isn't asked for: Docmost sets
    /// it only when its `APP_URL` says https, and a public server answers only over https here (App Transport Security).
    static func authToken(in cookies: [HTTPCookie], for server: URL) -> HTTPCookie? {
        guard let host = server.host()?.lowercased() else { return nil }
        return cookies.first { cookie in
            cookie.name == "authToken" && cookie.domain.lowercased() == host && cookie.isHTTPOnly
                && JWTClaims(token: cookie.value)?.isAccessToken == true
        }
    }

    /// Reads `authToken` from the WebView's cookie store (HttpOnly cookies are readable natively).
    private func checkForToken() async -> Bool {
        guard !captured else { return false }
        let cookies = await dataStore.httpCookieStore.allCookies()
        #if DEBUG
        if DebugLaunch.browserLogin {
            AppLog.session.notice("Browser cookies: \(cookies.map { "\($0.name)@\($0.domain)" }.joined(separator: ", "), privacy: .public)")
        }
        #endif
        guard let cookie = Self.authToken(in: cookies, for: server.url) else { return false }
        captured = true
        isFinishing = true
        await dataStore.httpCookieStore.deleteCookie(cookie)
        do {
            try await session.signIn(withToken: cookie.value, at: server)
            dismiss()
        } catch is CancellationError {
            // The app shows another server now (a link switched to it): this sign-in is over.
            dismiss()
        } catch {
            errorMessage = error.userMessage
            isFinishing = false
            captured = false
        }
        // On failure keep polling: the cookie is gone and the user can sign in again in this sheet.
        return captured
    }

    #if DEBUG
    /// Dev test helper: fills in and submits the web client's sign-in form like a user, so the HttpOnly cookie lands
    /// in the WebView as with SSO (`DOCMOST_DEBUG_BROWSER_LOGIN=1` + `DOCMOST_DEBUG_EMAIL/PASSWORD`).
    private func runDebugAutoLoginIfRequested() async {
        guard let email = DebugLaunch.email, let password = DebugLaunch.password,
              let body = try? JSONEncoder().encode(["email": email, "password": password]), let json = String(data: body, encoding: .utf8)
        else { return }
        let script = """
        try {
        const creds = \(json);
        let email, password, submit;
        // The React app renders the form only after loading; wait up to 10 seconds for it.
        for (let attempt = 0; attempt < 40; attempt++) {
            email = document.querySelector('input[type="email"], input[name="email"]');
            password = document.querySelector('input[type="password"]');
            submit = document.querySelector('button[type="submit"]');
            if (email && password && submit) { break; }
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
        if (!email || !password || !submit) { return "no form"; }
        const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
        for (const [field, value] of [[email, creds.email], [password, creds.password]]) {
            setter.call(field, value);
            field.dispatchEvent(new Event("input", { bubbles: true }));
            field.dispatchEvent(new Event("change", { bubbles: true }));
        }
        submit.click();
        return "submitted";
        } catch (e) {
            return "error " + (e && e.message) + " @ " + (e && e.stack);
        }
        """
        do {
            let status = try await page.callJavaScript(script)
            AppLog.session.notice("Debug browser login responded with \(String(describing: status), privacy: .public)")
        } catch {
            AppLog.session.notice("Debug browser login script failed: \(String(describing: error), privacy: .public)")
        }
    }
    #endif
}
