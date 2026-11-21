import CryptoKit
import Foundation
import Observation
import SwiftUI
import DocmostKit

/// The workspace's announcements (license feature `announcements`, Docmost 0.98) and the one the web would show now
/// (`announcement-banners.tsx`): running by the server's clock, the newest start first, not dismissed on this device.
/// `MainTabView` loads them while the app is active, every five minutes as the web does, and looks every 30 s whether
/// one started or ended; Home shows the bar.
@MainActor
@Observable
final class AnnouncementsStore {
    private(set) var shown: Announcement?
    @ObservationIgnored private var items: [Announcement] = []
    /// How far the server's clock is ahead of the device's, by its last answer.
    @ObservationIgnored private var clockOffset: TimeInterval = 0
    /// The server has no announcements (404, no enterprise code): asked no more while signed in, as the web stops.
    @ObservationIgnored private var unavailable = false
    private unowned let session: AppSession

    static let loadInterval: Duration = .seconds(300)
    static let checkInterval: Duration = .seconds(30)

    init(session: AppSession) {
        self.session = session
    }

    func load() async {
        guard session.ready?.entitlements.has("announcements") == true, !unavailable else {
            items = []
            update()
            return
        }
        do {
            let answer = try await session.send(Endpoints.Announcements.visible)
            items = answer.items
            clockOffset = answer.now?.timeIntervalSinceNow ?? 0
        } catch APIError.notFound {
            unavailable = true
            items = []
        } catch {
            // The last ones stay: a hiccup shouldn't take a running announcement away.
        }
        update()
    }

    /// Picks the announcement to show at `now` (the device's clock).
    func update(now: Date = .now) {
        let server = session.server?.url
        shown = Self.current(items, at: now.addingTimeInterval(clockOffset)) { item in
            server.map { Self.isDismissed(item, on: $0) } ?? false
        }
    }

    /// Hides `announcement` on this device until it changes, as the web keeps it in its local storage.
    func dismiss(_ announcement: Announcement) {
        guard let server = session.server?.url else { return }
        UserDefaults.standard.set(Self.fingerprint(of: announcement), forKey: Self.dismissedKey(announcement, on: server))
        update()
    }

    /// The running announcement with the latest start that isn't dismissed, at `serverNow` by the server's clock.
    nonisolated static func current(_ items: [Announcement], at serverNow: Date, isDismissed: (Announcement) -> Bool) -> Announcement? {
        items
            .filter { ($0.startsAt.map { $0 <= serverNow } ?? true) && ($0.endsAt.map { serverNow < $0 } ?? true) && !isDismissed($0) }
            .max { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
    }

    /// What a dismissal holds for: its type, color and text. One edited since shows again, as on the web.
    nonisolated static func fingerprint(of announcement: Announcement) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let parts: JSONValue = [.string(announcement.type ?? ""), .string(announcement.color ?? ""), announcement.content ?? .null]
        let data = (try? encoder.encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDismissed(_ announcement: Announcement, on server: URL) -> Bool {
        UserDefaults.standard.string(forKey: dismissedKey(announcement, on: server)) == fingerprint(of: announcement)
    }

    private static func dismissedKey(_ announcement: Announcement, on server: URL) -> String {
        "announcement.dismissed.\(server.absoluteString).\(announcement.id)"
    }
}

/// The announcement as the web's bar shows it (`announcement-banner.tsx`): its colors, its type's icon, its text
/// centered, and a close button where it may be dismissed.
struct AnnouncementBanner: View {
    let announcement: Announcement
    let serverURL: URL?
    let dismiss: () -> Void

    var body: some View {
        let colors = AnnouncementStyle.colors(announcement.color)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol = AnnouncementStyle.symbol(announcement.type) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(AnnouncementStyle.text(announcement.content, serverURL: serverURL))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if announcement.isDismissible == true {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Announcement")
                .accessibilityIdentifier("announcement-dismiss")
            }
        }
        .font(.subheadline)
        .foregroundStyle(colors.text)
        .tint(colors.text)
        .padding(12)
        .background(colors.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("announcement")
    }
}

/// The web's look of an announcement (`ee/announcement/constants.ts`, `announcement-content.tsx`, `utils.ts`).
enum AnnouncementStyle {
    struct Colors {
        let background: Color
        let text: Color
    }

    /// The preset's colors; an unknown one is gray, as on the web.
    static func colors(_ name: String?) -> Colors {
        let dark = Color(red: 0x1a / 255, green: 0x1b / 255, blue: 0x1e / 255)
        return switch name {
        case "blue": Colors(background: Color(red: 0x19 / 255, green: 0x71 / 255, blue: 0xc2 / 255), text: .white)
        case "green": Colors(background: Color(red: 0x2a / 255, green: 0x7d / 255, blue: 0x3d / 255), text: .white)
        case "yellow": Colors(background: Color(red: 0xfc / 255, green: 0xc4 / 255, blue: 0x19 / 255), text: dark)
        case "red": Colors(background: Color(red: 0xc9 / 255, green: 0x2a / 255, blue: 0x2a / 255), text: .white)
        case "purple": Colors(background: Color(red: 0x6e / 255, green: 0x5d / 255, blue: 0xc6 / 255), text: .white)
        case "black": Colors(background: Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255), text: .white)
        default: Colors(background: Color(red: 0xde / 255, green: 0xe2 / 255, blue: 0xe6 / 255), text: dark)
        }
    }

    static func symbol(_ type: String?) -> String? {
        switch type {
        case "info": "info.circle"
        case "success": "checkmark.circle"
        case "warning": "exclamationmark.triangle"
        case "critical": "exclamationmark.octagon"
        default: nil
        }
    }

    /// The announcement's paragraphs with their bold, italic, underline and links. A link goes only to the web, mail,
    /// or a path on the server ("/…", not "//…"), else it stays text, as the web's `isSafeHref` decides.
    static func text(_ content: JSONValue?, serverURL: URL?) -> AttributedString {
        let paragraphs = (content?["content"]?.arrayValue ?? []).map { paragraph in
            (paragraph["content"]?.arrayValue ?? []).reduce(into: AttributedString()) { line, node in
                guard let text = node["text"]?.stringValue else { return }
                var run = AttributedString(text)
                var intent = InlinePresentationIntent()
                for mark in node["marks"]?.arrayValue ?? [] {
                    switch mark["type"]?.stringValue {
                    case "bold": intent.insert(.stronglyEmphasized)
                    case "italic": intent.insert(.emphasized)
                    case "underline": run.underlineStyle = .single
                    case "link": run.link = link(mark["attrs"]?["href"]?.stringValue, serverURL: serverURL)
                    default: break
                    }
                }
                if !intent.isEmpty { run.inlinePresentationIntent = intent }
                if run.link != nil { run.underlineStyle = .single }
                line += run
            }
        }
        var joined = AttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { joined += AttributedString("\n") }
            joined += paragraph
        }
        return joined
    }

    static func link(_ href: String?, serverURL: URL?) -> URL? {
        guard let href = href?.trimmingCharacters(in: .whitespaces), !href.isEmpty else { return nil }
        if href.hasPrefix("/") {
            guard !href.hasPrefix("//"), let serverURL else { return nil }
            return URL(string: href, relativeTo: serverURL)?.absoluteURL
        }
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
