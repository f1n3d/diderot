import SwiftUI
import DocmostKit

/// Tabs in the reader (Docmost 0.97): the labels in a strip, the blocks of one tab at a time.
struct TabsBlockView: View {
    let tabs: [TabItem]
    /// The tab shown, by id; the first until one is picked.
    @State private var shown: String?

    var body: some View {
        let selected = tabs.first { $0.id == shown } ?? tabs.first
        TabsFrame {
            TabStrip(tabs: tabs.map { TabStrip.Tab(id: $0.id, label: $0.label) }, selected: selected?.id) { shown = $0 }
        } content: {
            if let selected {
                BlockStack(blocks: selected.blocks)
                    .id(selected.id)
            }
        }
    }
}

/// The frame both tab views share: the strip on top, the shown tab's blocks below, in a box like a callout's.
struct TabsFrame<Strip: View, Content: View>: View {
    @ViewBuilder let strip: Strip
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            strip
                .clearOfBlockActions()
            Divider()
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tabs"))
    }
}

/// The labels of a tabs block, scrolling sideways when they don't fit; the selected one is marked. `accessory` adds
/// views after the labels (the editor's "+"), `decorate` wraps each label (the editor's menu and drag).
struct TabStrip<Accessory: View, Decorated: View>: View {
    struct Tab: Identifiable, Hashable {
        let id: String
        let label: String
    }

    let tabs: [Tab]
    let selected: String?
    let select: (String) -> Void
    var decorate: (_ index: Int, _ slot: AnyView) -> Decorated
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        decorate(index, AnyView(slot(tab)))
                            .id(tab.id)
                    }
                    accessory
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: selected, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func slot(_ tab: Tab) -> some View {
        let isSelected = tab.id == selected
        return Button {
            select(tab.id)
        } label: {
            Text(tab.label.isEmpty ? String(localized: "Untitled") : tab.label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(alignment: .bottom) {
                    if isSelected {
                        Capsule().fill(Color.accentColor).frame(height: 2.5).padding(.horizontal, 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("tab-\(tab.label)")
    }
}

extension TabStrip where Accessory == EmptyView, Decorated == AnyView {
    /// The reader's strip: labels only.
    init(tabs: [Tab], selected: String?, select: @escaping (String) -> Void) {
        self.init(tabs: tabs, selected: selected, select: select, decorate: { $1 }, accessory: { EmptyView() })
    }
}
