import SwiftUI
import DocmostKit

/// Tabs while editing (Docmost 0.97): the strip switches tabs; holding a tab opens its menu (rename, duplicate, move,
/// delete), holding and moving it drags it to another place, and "+" adds one, then asks for its name as the web
/// does. The shown tab's blocks edit like any others; the tab holding the cursor or the current find match shows by
/// itself.
struct TabsNodeView: View {
    let model: DocumentModel
    let node: PMNode
    let ref: NodeRef
    @Environment(\.pageFind) private var find
    /// The tab shown, by identity (`NodeRef.identity`).
    @State private var shown: String?
    /// A tab just added: shown (and named) once the page has it.
    @State private var added: Int?
    @State private var renaming: Renaming?
    /// While a tab is dragged over another: that tab and which side it lands on.
    @State private var dropTarget: (id: String, before: Bool)?
    @State private var slotWidths: [String: CGFloat] = [:]

    private struct Renaming {
        let ref: NodeRef
        var label: String
    }

    private var tabs: [NodeEntry] {
        NodeEntry.entries(node.children, parentPath: ref.path).filter { $0.node.type == "tab" }
    }

    var body: some View {
        let tabs = tabs
        let selected = selectedIndex(in: tabs)
        TabsFrame {
            TabStrip(
                tabs: tabs.map { TabStrip.Tab(id: $0.id, label: DocumentModel.tabLabel(of: $0.node)) },
                selected: tabs.indices.contains(selected) ? tabs[selected].id : nil,
                select: { shown = $0 },
                decorate: { index, slot in
                    decorated(slot, index: index, of: tabs)
                },
                accessory: {
                    if model.isEditable {
                        Button {
                            Task {
                                if let path = await model.addTab(to: ref) { added = path.last }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 34, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Add Tab")
                        .accessibilityIdentifier("tabs-add")
                    }
                }
            )
        } content: {
            if tabs.indices.contains(selected) {
                panel(of: tabs[selected])
            }
        }
        .onChange(of: model.active?.ref.path) { _, path in reveal(path) }
        .onChange(of: find?.currentMatch?.ref.path) { _, path in reveal(path) }
        .onChange(of: tabs.map(\.id)) { _, ids in
            // The new tab arrived: show it and ask for its name.
            guard let index = added, ids.indices.contains(index) else { return }
            added = nil
            shown = ids[index]
            let tab = self.tabs[index]
            renaming = Renaming(ref: tab.ref, label: DocumentModel.tabLabel(of: tab.node))
        }
        .alert("Rename Tab", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Tab label", text: Binding { renaming?.label ?? "" } set: { renaming?.label = $0 })
                .accessibilityIdentifier("tab-name")
            Button("Rename") {
                guard let renaming else { return }
                Task { await model.renameTab(renaming.ref, to: renaming.label) }
            }
            .accessibilityIdentifier("tab-rename")
            Button("Cancel", role: .cancel) {}
        }
    }

    private func selectedIndex(in tabs: [NodeEntry]) -> Int {
        if let added, tabs.indices.contains(added) { return added }
        return tabs.firstIndex { $0.id == shown } ?? 0
    }

    @ViewBuilder
    private func panel(of tab: NodeEntry) -> some View {
        if let index = tab.node.children.firstIndex(where: { $0.type == "tabPanel" }) {
            NodeListView(model: model, nodes: tab.node.children[index].children, parentPath: tab.ref.path + [index])
                .id(tab.id)
        }
    }

    /// A tab of the strip: plain to read; while editing with its menu, dragging and the drop mark.
    private func decorated(_ slot: AnyView, index: Int, of tabs: [NodeEntry]) -> AnyView {
        guard model.isEditable else { return slot }
        let tab = tabs[index]
        let payload = Self.dragPrefix(model, ref) + tab.id
        let host = MenuDragTesting.showsMenu("tabs.tab")
            ? AnyView(MenuDragHost(content: slot, dragPayload: MenuDragTesting.allowsDrag("tabs.tab") ? payload : nil, cornerRadius: 8,
                                   menu: { menu(for: index, of: tabs) }))
            // UI tests without the tab menu: SwiftUI drag, which XCUITest can trigger (drop works as usual).
            : AnyView(slot.draggable(DragPayload.Item(payload: payload)))
        return AnyView(
            host
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { slotWidths[tab.id] = $0 }
                .overlay(alignment: dropTarget?.before == true ? .leading : .trailing) {
                    if dropTarget?.id == tab.id {
                        Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
                    }
                }
                .onDrop(of: DragPayload.types, delegate: TabDropDelegate(
                    prefix: Self.dragPrefix(model, ref), width: { slotWidths[tab.id] ?? 0 },
                    targeted: { before in dropTarget = before.map { (tab.id, $0) } },
                    drop: { identity, before in
                        guard let source = self.tabs.first(where: { $0.id == identity }) else { return }
                        Task { await model.moveTab(source.ref, to: tab.ref, before: before) }
                    }
                ))
        )
    }

    /// Tabs move only within their own block on this page.
    private static func dragPrefix(_ model: DocumentModel, _ ref: NodeRef) -> String {
        "docmost-tab:\(model.page.id)/\(ref.identity)/"
    }

    /// The tab's long-press menu (UIKit, as it must work together with dragging).
    private func menu(for index: Int, of tabs: [NodeEntry]) -> UIMenu {
        let tab = tabs[index]
        let model = model
        let tabsRef = ref
        let renaming = $renaming
        let moveLeft = UIAction(title: String(localized: "Move Left"), image: UIImage(systemName: "arrow.left"),
                                attributes: index == 0 ? .disabled : []) { _ in
            Task { await model.moveTab(tab.ref, to: tabs[index - 1].ref, before: true) }
        }
        let moveRight = UIAction(title: String(localized: "Move Right"), image: UIImage(systemName: "arrow.right"),
                                 attributes: index == tabs.count - 1 ? .disabled : []) { _ in
            Task { await model.moveTab(tab.ref, to: tabs[index + 1].ref, before: false) }
        }
        return UIMenu(children: [
            UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil")) { _ in
                renaming.wrappedValue = Renaming(ref: tab.ref, label: DocumentModel.tabLabel(of: tab.node))
            },
            UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square")) { _ in
                Task { await model.duplicateTab(tab.ref) }
            },
            moveLeft,
            moveRight,
            UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Delete Tab"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    Task { await model.deleteTab(tab.ref, in: tabsRef) }
                },
            ]),
        ])
    }

    /// Shows the tab that holds `path` (the cursor, a find match), if it lies in this block.
    private func reveal(_ path: [Int]?) {
        guard let path, path.count > ref.path.count + 1, path.starts(with: ref.path) else { return }
        let tabs = tabs
        let index = path[ref.path.count]
        if tabs.indices.contains(index) { shown = tabs[index].id }
    }
}

/// A tab dropped on another tab lands before or after it, by the half it was dropped on.
private struct TabDropDelegate: DropDelegate {
    let prefix: String
    let width: () -> CGFloat
    /// nil: no longer over this tab; else whether it would land before it.
    let targeted: (Bool?) -> Void
    let drop: (_ identity: String, _ before: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: DragPayload.types)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        targeted(info.location.x < width() / 2)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        targeted(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted(nil)
        let before = info.location.x < width() / 2
        return DragPayload.load(info, prefix: prefix) { identity in drop(identity, before) }
    }
}
