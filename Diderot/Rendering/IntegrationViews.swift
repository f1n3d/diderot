import SwiftUI
import WebKit
import DocmostKit

/// Previews of links to other services (Docmost 0.97 integration cards and mentions) for one server: each link is
/// asked about once in a while, and the answers stay on disk for reading offline.
@MainActor
@Observable
final class LinkPreviewStore {
    enum State: Equatable {
        case loading
        /// nil: no installed integration previews the link.
        case loaded(LinkPreview?)
        case failed
    }

    private(set) var states: [String: State] = [:]
    /// The workspace's installed integrations; nil until known.
    private(set) var installed: [Integration]?

    @ObservationIgnored private let client: APIClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    /// When the installed integrations were last asked for.
    @ObservationIgnored private var installedAskedAt: Date?

    init(client: APIClient, cache: DiskCache) {
        self.client = client
        self.cache = cache
    }

    /// Hosts per service the workspace previews besides the services' own (`IntegrationLinks.describe`).
    var unfurlHosts: [String: [String]] {
        Dictionary((installed ?? []).compactMap { integration in integration.unfurlHosts.map { (integration.type, $0) } }) { $0 + $1 }
    }

    var installedTypes: Set<String> { Set((installed ?? []).map(\.type)) }

    func preview(for url: String) -> LinkPreview.Preview? {
        if case .loaded(.preview(let preview))? = states[url] { return preview }
        return nil
    }

    /// Asks for the installed integrations once in 10 minutes (an admin may install one meanwhile); pasting needs them
    /// to recognize a link, cards and mentions for hosts other than the services' own.
    func loadInstalled() async {
        if let installedAskedAt, installedAskedAt.timeIntervalSinceNow > -600 { return }
        installedAskedAt = .now
        if let answer = try? await client.send(Endpoints.Integrations.installed) {
            installed = answer
        } else if installed == nil {
            installedAskedAt = nil
        }
    }

    /// Asks the server about links not asked about in the last 10 minutes (or again with `force`), a few at a time;
    /// meanwhile and offline, a saved answer shows.
    func load(_ urls: [String], force: Bool = false) async {
        let due = Array(Set(urls)).filter { url in
            !url.isEmpty && (force || askedAt[url].map { $0.timeIntervalSinceNow < -600 } ?? true)
        }
        guard !due.isEmpty else { return }
        await loadInstalled()
        for url in due { askedAt[url] = .now }
        for url in due where states[url] == nil {
            if let saved = await cache.read(UnfurlResponse.self, key: Self.key(url)) {
                states[url] = .loaded(saved.data)
            } else {
                states[url] = .loading
            }
        }
        await withTaskGroup(of: (String, UnfurlResponse?).self) { group in
            var pending = due[...]
            func next() {
                guard let url = pending.popFirst() else { return }
                group.addTask { [client] in (url, try? await client.send(Endpoints.Integrations.unfurl(url))) }
            }
            for _ in 0..<4 { next() }
            for await (url, answer) in group {
                if let answer {
                    states[url] = .loaded(answer.data)
                    await cache.write(answer, key: Self.key(url))
                } else if states[url] == .loading {
                    states[url] = .failed
                    askedAt[url] = nil
                }
                next()
            }
        }
    }

    private static func key(_ url: String) -> String { "linkPreview/\(url)" }
}

extension EnvironmentValues {
    /// The current server's link previews; nil before sign-in and in previews.
    @Entry var linkPreviews: LinkPreviewStore?
}

extension View {
    /// Asks the server about the integration mentions in `inlines`, so they show the services' titles.
    func loadsLinkPreviews(for inlines: [Inline]) -> some View {
        modifier(LinkPreviewLoading(urls: inlines.integrationURLs))
    }
}

private struct LinkPreviewLoading: ViewModifier {
    let urls: [String]
    @Environment(\.linkPreviews) private var previews

    func body(content: Content) -> some View {
        if urls.isEmpty {
            content
        } else {
            content.task(id: urls) { await previews?.load(urls) }
        }
    }
}

extension [Inline] {
    /// The addresses of the integration mentions here.
    var integrationURLs: [String] {
        compactMap { inline in
            switch inline {
            case .integrationMention(let link): link.url
            case .marked(.integrationMention(let link), _): link.url
            default: nil
            }
        }
    }
}

// MARK: - Card

/// A link to another service as a card: what the server tells about it, or what its address does.
struct IntegrationCardView: View {
    let link: IntegrationLink
    @Environment(\.linkPreviews) private var previews
    @Environment(\.renderContext) private var context
    @Environment(\.openURL) private var openURL
    /// The service whose account the user connects in the sheet.
    @State private var connecting: ConnectRequest?

    private var described: IntegrationLinks.Description {
        IntegrationLinks.describe(link.url, unfurlHosts: previews?.unfurlHosts ?? [:])
    }

    var body: some View {
        let state = previews?.states[link.url]
        // "Connect" lies outside the card's button, so it can be tapped (and found by VoiceOver) on its own.
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = URL(string: link.url) { openURL(url) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    switch state {
                    case .loaded(.preview(let preview))?:
                        previewContent(preview)
                    case .loaded(.needsConnection(let needed))?:
                        Text(needed.title.isEmpty ? described.title : needed.title).font(.headline).lineLimit(2)
                    case .loading?:
                        Text(described.title).font(.headline).lineLimit(2)
                        ProgressView().controlSize(.small)
                    default:
                        Text(described.title).font(.headline).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("integration-card")
            if case .loaded(.needsConnection(let needed))? = state {
                connectButton(needed)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: link.url) { await previews?.load([link.url]) }
        .sheet(item: $connecting, onDismiss: {
            Task { await previews?.load([link.url], force: true) }
        }) { request in
            if let server = context.baseURL {
                IntegrationConnectSheet(server: server, token: context.token, type: request.type)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: IntegrationStyle.symbol(for: described.kind))
                .foregroundStyle(Color.accentColor)
            Text(IntegrationStyle.caption(provider: described.provider, kind: described.kind, fallback: link.provider))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
        }
        .font(.caption)
        .clearOfBlockActions(inset: 12)
    }

    @ViewBuilder
    private func previewContent(_ preview: LinkPreview.Preview) -> some View {
        Text(preview.title.isEmpty ? described.title : preview.title).font(.headline).lineLimit(2)
        let details = IntegrationStyle.details(preview, kind: described.kind)
        if preview.status != nil || !details.isEmpty {
            HStack(spacing: 6) {
                if let status = preview.status, !status.isEmpty {
                    StatusBadge(text: status, color: preview.statusColor)
                }
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        if let description = preview.description, !description.isEmpty {
            Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    private func connectButton(_ needed: LinkPreview.ConnectionNeeded) -> some View {
        Button {
            connecting = ConnectRequest(type: needed.integrationType)
        } label: {
            Label("Connect to \(needed.integrationName) to preview", systemImage: "link.badge.plus")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("integration-connect")
    }
}

private struct ConnectRequest: Identifiable {
    let type: String
    var id: String { type }
}

/// Connects the user's account to a service in the web's own settings page (`connections?connect=<type>`): the server
/// only completes the service's sign-in in the browser that started it, with the user's session and a one-time cookie,
/// so the whole flow runs in this web view, signed in like the web editor. The services' sign-in pages load here too;
/// the bar names the host shown.
struct IntegrationConnectSheet: View {
    let server: URL
    let token: String?
    let type: String
    @Environment(\.dismiss) private var dismiss
    @State private var page: WebPage
    @State private var dataStore: WKWebsiteDataStore

    init(server: URL, token: String?, type: String) {
        self.server = server
        self.token = token
        self.type = type
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        _dataStore = State(initialValue: dataStore)
        _page = State(initialValue: WebPage(configuration: configuration))
    }

    var body: some View {
        NavigationStack {
            WebView(page)
                .overlay { if page.isLoading { ProgressView() } }
                .navigationTitle(page.url?.host() ?? server.host() ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("integration-connect-done")
                    }
                }
        }
        .task {
            if let cookie = HTTPCookie.docmostAuth(token: token, serverURL: server) {
                await dataStore.httpCookieStore.setCookie(cookie)
            }
            var components = URLComponents(url: server.appending(path: "settings/account/connections"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "connect", value: type)]
            if let url = components?.url { page.load(URLRequest(url: url)) }
        }
    }
}

/// A preview's status in the service's color.
struct StatusBadge: View {
    let text: String
    let color: String?

    var body: some View {
        let tint = IntegrationStyle.statusColor(color)
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Symbols, names and colors of integration links: own symbols per kind, no service logos.
enum IntegrationStyle {
    static func symbol(for kind: IntegrationLinks.Kind) -> String {
        switch kind {
        case .repository: "books.vertical"
        case .issue: "smallcircle.filled.circle"
        case .pullRequest, .mergeRequest: "arrow.triangle.merge"
        case .commit: "circle.and.line.horizontal"
        case .file: "doc.text"
        case .folder: "folder"
        case .discussion: "bubble.left.and.bubble.right"
        case .release: "tag"
        case .project: "square.stack.3d.up"
        case .initiative: "flag"
        case .view: "line.3.horizontal.decrease.circle"
        case .design: "paintpalette"
        case .prototype: "play.rectangle"
        case .board: "rectangle.3.group"
        case .slides: "rectangle.on.rectangle"
        case .workItem: "checklist"
        case .message: "bubble.left"
        case .page: "link"
        }
    }

    static func kindName(_ kind: IntegrationLinks.Kind) -> String {
        switch kind {
        case .repository: String(localized: "Repository")
        case .issue: String(localized: "Issue")
        case .pullRequest: String(localized: "Pull request")
        case .mergeRequest: String(localized: "Merge request")
        case .commit: String(localized: "Commit")
        case .file: String(localized: "File")
        case .folder: String(localized: "Folder")
        case .discussion: String(localized: "Discussion")
        case .release: String(localized: "Release")
        case .project: String(localized: "Project")
        case .initiative: String(localized: "Initiative")
        case .view: String(localized: "View")
        case .design: String(localized: "Design")
        case .prototype: String(localized: "Prototype")
        case .board: String(localized: "Board")
        case .slides: String(localized: "Slides")
        case .workItem: String(localized: "Work item")
        case .message: String(localized: "Message")
        case .page: String(localized: "Link")
        }
    }

    /// "GitHub · Issue"; for an unknown service the stored provider name.
    static func caption(provider: IntegrationLinks.Provider?, kind: IntegrationLinks.Kind, fallback: String) -> String {
        let service = provider?.name ?? (fallback.isEmpty ? nil : fallback.capitalized)
        return [service, kind == .page ? nil : kindName(kind)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Who and when, as far as the preview tells: "Assigned to Alex · Updated 2 hours ago".
    static func details(_ preview: LinkPreview.Preview, kind: IntegrationLinks.Kind) -> String {
        var parts: [String] = []
        if let author = preview.author, !author.isEmpty {
            switch kind {
            case .issue, .pullRequest, .mergeRequest, .workItem: parts.append(String(localized: "Assigned to \(author)"))
            case .design, .prototype, .board, .slides, .file: parts.append(String(localized: "Last modified by \(author)"))
            default: parts.append(author)
            }
        }
        if let replies = preview.metadata?["replyCount"]?.intValue, replies > 0 {
            parts.append(String(localized: "\(replies) replies"))
        }
        if let updated = preview.metadata?["updatedAt"]?.stringValue.flatMap(Self.date) {
            parts.append(String(localized: "Updated \(updated.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    /// The services name their colors ("green", "blue-gray") or give hex.
    static func statusColor(_ name: String?) -> Color {
        guard let name = name?.lowercased(), !name.isEmpty else { return .secondary }
        if name.hasPrefix("#"), let color = Color(hex: name) { return color }
        if name.contains("green") { return .green }
        if name.contains("purple") || name.contains("violet") { return .purple }
        if name.contains("red") { return .red }
        if name.contains("yellow") || name.contains("orange") { return .orange }
        if name.contains("blue") && !name.contains("gray") { return .blue }
        return .secondary
    }

    private static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}
