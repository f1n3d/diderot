import SwiftUI
import DocmostKit

/// Space logo, or its initial in the app's forest green (Docmost has no colors for spaces).
struct SpaceLogoView: View {
    let space: Space
    let baseURL: URL?
    var size: CGFloat = 36

    var body: some View {
        RemoteThumbnail(url: baseURL.flatMap { ImageURL.resolve(space.logo, kind: .spaceIcon, baseURL: $0) }, server: baseURL,
                        size: size, shape: RoundedRectangle(cornerRadius: size * 0.25)) { initial }
    }

    private var initial: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                Text(String(space.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
    }
}

/// Remote avatar or logo at a fixed size and shape; placeholder without a URL, while loading and on failure. From another
/// server only with Settings › "Load Content from Other Servers" on, as page media (`RenderContext.loadsByItself`): a
/// logo from elsewhere told that host who opened the app and when.
struct RemoteThumbnail<ClipShape: Shape, Placeholder: View>: View {
    let url: URL?
    /// The server the avatar or logo belongs to.
    let server: URL?
    let size: CGFloat
    let shape: ClipShape
    @ViewBuilder let placeholder: Placeholder
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loaded: URL?

    /// What it loads: `url` where it may load by itself.
    var source: URL? {
        url.flatMap { RenderContext.loadsByItself($0, server: server) ? $0 : nil }
    }

    var body: some View {
        if let url = source {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(shape)
            // Decoded at the size shown, as content images are. AsyncImage decoded the whole file: a member's avatar that
            // is small as a file but huge unpacked ended the app wherever it showed. Same request as before: no token.
            .task(id: url) {
                if loaded == url, image != nil { return }
                image = nil
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                image = await ImageLoader.decode(data, targetPixelWidth: Int((size * displayScale).rounded(.up)))
                loaded = url
            }
        } else {
            placeholder
        }
    }
}

/// Emoji icon of a page, or a placeholder.
struct PageIconView: View {
    let icon: String?
    var size: CGFloat = 18
    /// Base (database) page: without an emoji it shows a table symbol, not the document one (web parity).
    var isBase = false

    var body: some View {
        if let icon, !icon.isEmpty {
            Text(icon)
                .font(.system(size: size))
                .frame(width: size + 6, height: size + 6)
                .accessibilityHidden(true)
        } else {
            Image(systemName: isBase ? "tablecells" : "doc.text")
                .font(.system(size: size - 2))
                .foregroundStyle(.secondary)
                .frame(width: size + 6, height: size + 6)
                .accessibilityHidden(true)
        }
    }
}

extension Color {
    /// Stable color per user name, so people's initials stay recognizable.
    static func tint(for id: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[hash % palette.count]
    }
}

/// Navigation to a space by ID only (favorites, deep links); loads the space info afterwards.
struct SpaceRoute: Hashable {
    let spaceId: String
}

struct SpaceRouteView: View {
    @Environment(AppSession.self) private var session
    let route: SpaceRoute
    @State private var state: LoadState<Space> = .idle

    var body: some View {
        AsyncContentView(state: state, retry: load) { space in
            SpaceView(space: space)
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        guard let ready = session.ready else { return }
        state = .loading
        do {
            state = .loaded(try await session.send(Endpoints.Spaces.info(spaceId: route.spaceId)))
        } catch is CancellationError {
        } catch let error as APIError where error.isGone {
            // Deleted or no longer shared: say so instead of showing the saved header.
            state = .failed(error)
        } catch {
            // Offline or server error: use the saved space list (the Spaces tab opens the same entries).
            if let cached = await ready.cache.read([Space].self, key: CacheKey.spaces)?.first(where: { $0.id == route.spaceId }) {
                state = .loaded(cached)
            } else {
                state = .failed(error)
            }
        }
    }
}
