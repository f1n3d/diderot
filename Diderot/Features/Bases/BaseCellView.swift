import SwiftUI
import DocmostKit

/// Cell value: compact (one line, in table and card) or detail sheet (full, links tappable).
struct BaseCellView: View {
    enum Style {
        case compact, detail
    }

    @Environment(AppSession.self) private var session
    let property: BaseProperty
    let row: BaseRow
    let users: [String: UserRef]
    let pages: [String: PageRef]
    var style: Style = .compact
    /// Page reference tapped (detail style only).
    var onOpenPage: ((PageRef) -> Void)?

    private var value: JSONValue? {
        guard let value = row.cells[property.id], !value.isNull else { return nil }
        return value
    }

    var body: some View {
        switch property.kind {
        case .text, .longText:
            text(value?.stringValue)
        case .number:
            number
        case .select, .status:
            pills(value?.stringValue.map { [$0] } ?? [])
        case .multiSelect:
            pills(BaseLayout.stringArray(value) ?? [])
        case .date:
            text(value?.stringValue.map { BaseFormat.date($0, options: property.typeOptions) })
        case .person:
            people(BaseValue.personIds(value))
        case .page:
            page(value?.stringValue)
        case .file:
            files
        case .checkbox:
            checkbox(value?.boolValue == true)
        case .url:
            link(value?.stringValue, url: value?.stringValue.flatMap(BaseValue.openURL))
        case .email:
            link(value?.stringValue, url: value?.stringValue.flatMap { URL(string: "mailto:\($0)") })
        case .createdAt:
            text(row.createdAt.map(BaseFormat.timestamp))
        case .lastEditedAt:
            text(row.updatedAt.map(BaseFormat.timestamp))
        case .lastEditedBy:
            people([row.lastUpdatedById ?? row.creatorId].compactMap { $0 })
        case .formula:
            formula
        case nil:
            if style == .detail {
                Text("Only in the web app").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Property types

    @ViewBuilder
    private func text(_ string: String?) -> some View {
        if let string, !string.isEmpty {
            Text(style == .compact ? string.replacingOccurrences(of: "\n", with: " ") : string)
                .lineLimit(style == .compact ? 1 : nil)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var number: some View {
        if let number = value?.doubleValue {
            let label = BaseFormat.number(number, options: property.typeOptions)
            if BaseFormat.isProgress(property.typeOptions) {
                HStack(spacing: 8) {
                    ProgressView(value: min(100, max(0, number)), total: 100)
                        .frame(maxWidth: style == .compact ? 70 : 160)
                    Text(label).monospacedDigit()
                }
            } else {
                Text(label).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func pills(_ ids: [String]) -> some View {
        let all = BaseLayout.choices(of: property)
        let chosen = ids.compactMap { id in all.first { $0.id == id } }
        if !chosen.isEmpty {
            if style == .compact {
                HStack(spacing: 4) {
                    ForEach(chosen.prefix(2), id: \.id) { ChoicePill(choice: $0) }
                    if chosen.count > 2 {
                        Text("+\(chosen.count - 2)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(chosen, id: \.id) { ChoicePill(choice: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func people(_ ids: [String]) -> some View {
        let resolved = ids.map { id in users[id] ?? UserRef(id: id, name: nil, avatarUrl: nil) }
        if !resolved.isEmpty {
            let layout = style == .compact ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            layout {
                ForEach(resolved.prefix(style == .compact ? 2 : resolved.count), id: \.id) { user in
                    HStack(spacing: 6) {
                        AvatarView(name: user.name, avatarUrl: user.avatarUrl, baseURL: session.server?.url, size: 20)
                        Text(user.name ?? String(localized: "Unknown")).lineLimit(1)
                    }
                }
                if style == .compact, resolved.count > 2 {
                    Text("+\(resolved.count - 2)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func page(_ id: String?) -> some View {
        if let id {
            let reference = pages[id] ?? PageRef(id: id)
            let label = HStack(spacing: 4) {
                PageIconView(icon: reference.icon, size: 14)
                Text(PageTitle.display(reference.title)).lineLimit(1)
            }
            if style == .detail, let onOpenPage {
                Button { onOpenPage(reference) } label: { label }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            } else {
                label
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        let names = (value?.arrayValue ?? []).compactMap { $0["fileName"]?.stringValue }
        if !names.isEmpty {
            if style == .compact {
                Label(names.count == 1 ? names[0] : String(localized: "\(names.count) files"), systemImage: "paperclip")
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(names, id: \.self) { Label($0, systemImage: "paperclip") }
                }
            }
        }
    }

    private func checkbox(_ checked: Bool) -> some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .foregroundStyle(checked ? Color.accentColor : .secondary)
            .accessibilityLabel(checked ? Text("Yes") : Text("No"))
    }

    @ViewBuilder
    private func link(_ text: String?, url: URL?) -> some View {
        if let text, !text.isEmpty {
            if style == .detail, let url {
                Link(text, destination: url).lineLimit(2)
            } else {
                Text(text).foregroundStyle(Color.accentColor).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var formula: some View {
        switch value {
        case .number(let number):
            Text(BaseFormat.number(number, options: nil)).monospacedDigit()
        case .string(let string):
            text(property.typeOptions?["resultType"]?.stringValue == "date" ? BaseFormat.date(string, options: nil) : string)
        case .bool(let flag):
            checkbox(flag)
        case .object(let object) where object["__err"] != nil:
            Text("#ERROR").foregroundStyle(.red).help(object["msg"]?.stringValue ?? "")
        default:
            EmptyView()
        }
    }
}

/// Colored pill for a choice value.
struct ChoicePill: View {
    let choice: BaseChoice

    var body: some View {
        Text(choice.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(BaseChoiceColor.foreground(choice.color))
            .background(BaseChoiceColor.background(choice.color), in: Capsule())
    }
}

/// Flow layout: items side by side, wrapping when the line is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Frames relative to the top left, and the total size. Items wider than the line get its width so pills truncate.
    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }
}
