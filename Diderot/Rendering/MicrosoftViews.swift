import SwiftUI
import DocmostKit

/// Files or a folder in SharePoint or OneDrive (Docmost 0.98's Microsoft 365 blocks), as a card of links: the web frames
/// Microsoft's preview, which needs the user's Microsoft sign-in; here each opens in the browser.
struct MicrosoftItemsView: View {
    let items: [MicrosoftItem]
    let isFolder: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isFolder ? "SharePoint Folder" : "SharePoint", systemImage: isFolder ? "folder" : "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("No files").foregroundStyle(.secondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    if let url = item.webURL.flatMap({ ContentLinkRouter.contentURL($0.absoluteString) }) { openURL(url) }
                } label: {
                    Label(item.title.isEmpty ? String(localized: "Untitled") : item.title,
                          systemImage: isFolder ? "folder.fill" : "doc.text")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.webURL == nil)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier(isFolder ? "microsoft-folder" : "microsoft-files")
    }
}
