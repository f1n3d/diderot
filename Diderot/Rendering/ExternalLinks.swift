import SafariServices
import SwiftUI

extension View {
    /// Opens the links tapped in here that leave the app as the web client in a browser does: web pages in the in-app
    /// browser, mail, phone and messages through the system, another app only after asking, scripts and files never,
    /// saying so (`ContentLinkRouter.opening(for:)`). Every sheet that shows links needs its own: a view can't present
    /// over a sheet it shows.
    func opensExternalLinks() -> some View {
        modifier(ExternalLinks())
    }

    /// Links tapped in here go to `handle`, with `outside` (the enclosing `opensExternalLinks()`) for those that leave
    /// the app.
    func handlesLinks(_ handle: @escaping (_ url: URL, _ outside: OpenURLAction) -> Void) -> some View {
        transformEnvironment(\.openURL) { action in
            let outside = action
            action = OpenURLAction { url in
                handle(url, outside)
                return .handled
            }
        }
    }
}

private struct ExternalLinks: ViewModifier {
    @State private var webPage: URL?
    @State private var otherApp: URL?
    @State private var notice: String?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                switch ContentLinkRouter.opening(for: url) {
                case .browser: webPage = url
                case .system: return .systemAction
                case .askFirst: otherApp = url
                case .never: notice = String(localized: "This link can't be opened.")
                }
                return .handled
            })
            .sheet(item: $webPage) { url in
                SafariView(url: url).ignoresSafeArea()
            }
            .alert("Open in Another App?", isPresented: Binding { otherApp != nil } set: { if !$0 { otherApp = nil } },
                   presenting: otherApp) { url in
                Button("Open") { open(url) }
                Button("Cancel", role: .cancel) {}
            } message: { url in
                Text(url.absoluteString)
            }
            .toast($notice)
    }

    private func open(_ url: URL) {
        Task {
            if await !UIApplication.shared.open(url) { notice = String(localized: "No app can open this link.") }
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
