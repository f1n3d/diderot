import SwiftUI
import DocmostKit

/// Space logo, or its initial on a colored background.
struct SpaceLogoView: View {
    let space: Space
    let baseURL: URL?
    var size: CGFloat = 36

    var body: some View {
        RemoteThumbnail(url: baseURL.flatMap { ImageURL.resolve(space.logo, kind: .spaceIcon, baseURL: $0) }, size: size,
                        shape: RoundedRectangle(cornerRadius: size * 0.25)) { initial }
    }

    private var initial: some View {
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(Color.tint(for: space.id).opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                Text(String(space.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Color.tint(for: space.id))
            }
            .accessibilityHidden(true)
    }
}

/// Remote avatar or logo at a fixed size and shape; placeholder without a URL, while loading and on failure.
struct RemoteThumbnail<ClipShape: Shape, Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    let shape: ClipShape
    @ViewBuilder let placeholder: Placeholder

    var body: some View {
        if let url {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { placeholder }
                .frame(width: size, height: size)
                .clipShape(shape)
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
    /// Stable color per space ID or user name, so initials stay recognizable.
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
