import SafariServices
import SwiftUI

extension View {
    /// Opens the links tapped in here that leave the app as the web client in a browser does: web pages in the in-app
    /// browser, mail, phone and messages through the system, another app only after asking, scripts and files never,
    /// saying so (`ContentLinkRouter.opening(for:)`). Every sheet needs its own, as a view can't present over a sheet it
    /// shows: the app's sheets get it from `linkSheet` and its siblings.
    func opensExternalLinks() -> some View {
        modifier(ExternalLinks())
    }

    /// A sheet whose links open as the page's do (`opensExternalLinks`). Presented with `sheet`, a sheet got the handler
    /// of the view that showed it, which can't present over it: its links did nothing. The app presents its sheets,
    /// full-screen covers and popovers only through these (`Tools/check-project.sh` checks it).
    func linkSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                  @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().opensExternalLinks() }
    }

    func linkSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                      @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).opensExternalLinks() }
    }

    func linkFullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().opensExternalLinks() }
    }

    func linkFullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { content($0).opensExternalLinks() }
    }

    func linkPopover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented) { content().opensExternalLinks() }
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
