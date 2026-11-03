import SwiftUI
import DocmostKit

/// Suggestions for "@": pages and people.
struct MentionMenuView: View {
    let model: DocumentModel
    @Environment(\.renderContext) private var context

    var body: some View {
        let suggestions = Array(model.mentionSuggestions.prefix(8))
        VStack(alignment: .leading, spacing: 0) {
            if suggestions.isEmpty {
                Text(model.mentionQuery?.isEmpty == false ? "No matches" : "Mention a page or person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(suggestions) { suggestion in
                Button {
                    model.insertMention(suggestion)
                } label: {
                    HStack(spacing: 10) {
                        if suggestion.kind == .user {
                            AvatarView(name: suggestion.title, avatarUrl: suggestion.avatarUrl, baseURL: context.baseURL, size: 24)
                        } else {
                            PageIconView(icon: suggestion.icon, size: 18)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title).lineLimit(1)
                            if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mention-\(suggestion.id)")
                if suggestion.id != suggestions.last?.id {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Insert menu below the active block: filtered by the query after "/", complete after "+". Entries in web editor
/// order; scrolls beyond `maxHeight`.
struct InsertMenuView: View {
    let model: DocumentModel
    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 264

    var body: some View {
        let matches = model.insertMatches
        Group {
            if matches.isEmpty {
                Text("No matching block")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { command in
                            row(command)
                            if command.id != matches.last?.id {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
                .scrollIndicatorsFlash(onAppear: true)
                // New query: start at the top again.
                .id(model.slashQuery ?? "+")
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ command: InsertCommand) -> some View {
        let enabled = model.isEnabled(command)
        return Button {
            model.perform(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(command.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !enabled {
                    Image(systemName: "lock")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Not included in your plan")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityIdentifier("slash-\(command.id)")
    }
}
