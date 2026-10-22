import SwiftUI
import DocmostKit

/// Kanban board like Trello and Jira: horizontally snapping columns (`KanbanBoardLayout`), each scrolling on its own.
/// With write permission, cards can be dragged within and between columns, moved via "Move to" and created per column.
/// Menu and drag live on a UIKit card wrapper (`KanbanCardHost`); drops go through SwiftUI `DropDelegate`s.
struct BaseKanbanView: View {
    let model: BaseModel
    let base: Base
    let view: BaseView
    let onOpen: (BaseRowRoute) -> Void
    @State private var drag = KanbanDragState()
    @State private var position = ScrollPosition()
    /// Board offset, for paging at the edge while dragging and for scrolling to a new card.
    @State private var offsetX: CGFloat = 0

    var body: some View {
        if BaseLayout.groupByProperty(base: base, view: view) == nil {
            ContentUnavailableView(
                "Board without grouping", systemImage: "rectangle.split.3x1",
                description: Text("This board isn't grouped by a select or status property. Set the grouping in the web editor.")
            )
        } else {
            let cardProperties = BaseLayout.cardProperties(base: base, view: view)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: KanbanBoardLayout.spacing) {
                    ForEach(model.columns) { column in
                        KanbanColumnView(
                            model: model, column: column, cardProperties: cardProperties, drag: drag, onOpen: onOpen
                        )
                        .containerRelativeFrame(.horizontal) { length, _ in KanbanBoardLayout.columnWidth(board: length) }
                    }
                }
                .padding(.horizontal, KanbanBoardLayout.padding)
                .padding(.vertical, 12)
            }
            .scrollPosition($position)
            .scrollTargetBehavior(KanbanColumnSnapping(columnCount: model.columns.count))
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drag.boardWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offsetX = x }
            .onChange(of: drag.scrollRequest) { _, request in
                if let request { scroll(by: request.direction) }
            }
            .onChange(of: model.lastCreatedRowId) { _, rowId in
                // New card: scroll to its column.
                guard let rowId, let index = model.columns.firstIndex(where: { $0.list.rows.contains { $0.id == rowId } }) else { return }
                let x = KanbanBoardLayout.offset(column: index, count: model.columns.count, board: drag.boardWidth)
                // Already in place: skip a zero-distance scroll animation.
                guard abs(x - offsetX) > 1 else { return }
                withAnimation { position.scrollTo(x: x) }
            }
            .overlay {
                if model.columns.isEmpty, model.isLoadingRows {
                    ProgressView()
                } else if model.columns.isEmpty, let error = model.rowsError {
                    ErrorStateView(error: error) { await model.load() }
                }
            }
            .accessibilityIdentifier("base-kanban")
        }
    }

    /// Scrolls one column left (-1) or right (1) while a card is held at the edge.
    private func scroll(by direction: Int) {
        let offsets = KanbanBoardLayout.offsets(count: model.columns.count, board: drag.boardWidth)
        let next = direction > 0 ? offsets.first { $0 > offsetX + 1 } : offsets.last { $0 < offsetX - 1 }
        guard let next else { return }
        withAnimation(.easeInOut(duration: 0.3)) { position.scrollTo(x: next) }
    }
}

// MARK: - Snapping

/// Board metrics and snap points: a column's center snaps to the visible board's center, clamped at the ends (first
/// column flush left, last flush right). In between, neighbors peek out on both sides so cards drag into them easily.
nonisolated enum KanbanBoardLayout {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16

    static func columnWidth(board: CGFloat) -> CGFloat {
        min(board * 0.85, 340)
    }

    /// Board offset at which `column` is snapped.
    static func offset(column: Int, count: Int, board: CGFloat) -> CGFloat {
        let width = columnWidth(board: board)
        let content = 2 * padding + CGFloat(count) * width + CGFloat(max(count - 1, 0)) * spacing
        let center = padding + CGFloat(column) * (width + spacing) + width / 2
        return min(max(center - board / 2, 0), max(content - board, 0))
    }

    /// All snap points left to right; on wide boards, columns near the ends can share one point.
    static func offsets(count: Int, board: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        for column in 0..<max(count, 0) {
            let x = offset(column: column, count: count, board: board)
            if let last = result.last, abs(last - x) < 1 { continue }
            result.append(x)
        }
        return result
    }
}

/// Swipe snapping per `KanbanBoardLayout`. Columns wider than half the board (iPhone portrait): a swipe moves at most
/// one column like `.viewAligned`, but a short swipe suffices. Wider boards snap to the nearest column.
struct KanbanColumnSnapping: ScrollTargetBehavior {
    let columnCount: Int

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let board = context.containerSize.width
        let offsets = KanbanBoardLayout.offsets(count: columnCount, board: board)
        guard board > 0, !offsets.isEmpty else { return }
        func nearest(_ x: CGFloat) -> Int {
            offsets.indices.min { abs(offsets[$0] - x) < abs(offsets[$1] - x) } ?? 0
        }
        let proposed = target.rect.minX
        var index = nearest(proposed)
        if KanbanBoardLayout.columnWidth(board: board) > board / 2 {
            let start = nearest(context.originalTarget.rect.minX)
            let delta = proposed - offsets[start]
            if delta > 0, start + 1 < offsets.count, delta > (offsets[start + 1] - offsets[start]) * 0.2 {
                index = start + 1
            } else if delta < 0, start > 0, -delta > (offsets[start] - offsets[start - 1]) * 0.2 {
                index = start - 1
            } else {
                index = start
            }
        }
        target.rect.origin.x = offsets[index]
    }

    /// Paging-like deceleration: a snap to a middle column used to coast slowly, while one to an end column hit the
    /// edge at full speed.
    func properties(context: PropertiesContext) -> Properties {
        var properties = Properties()
        properties.limitsScrolls = true
        return properties
    }
}

// MARK: - Drag and drop

/// Where a dragged card would land: before or after a card, or at a column's end.
struct KanbanDropTarget: Equatable {
    let columnId: String
    /// Card to drop at; `nil` = end of the column.
    let rowId: String?
    var below = false
}

/// Shared board state while dragging: dragged card, insertion mark and paging at the edge.
@MainActor
@Observable
final class KanbanDragState {
    struct ScrollRequest: Equatable {
        let direction: Int
        let id = UUID()
    }

    /// Dragged card, dimmed at its original position.
    var draggedRowId: String?
    var target: KanbanDropTarget?
    private(set) var scrollRequest: ScrollRequest?
    @ObservationIgnored var boardWidth: CGFloat = 0
    @ObservationIgnored private var edgeDirection = 0
    @ObservationIgnored private var edgeTask: Task<Void, Never>?

    /// Finger at the edge (x in visible board coordinates): pages one column per short pause while it stays there.
    func hover(atBoardX x: CGFloat) {
        let margin: CGFloat = 44
        let direction = x < margin ? -1 : (boardWidth > 0 && x > boardWidth - margin ? 1 : 0)
        guard direction != edgeDirection else { return }
        edgeDirection = direction
        edgeTask?.cancel()
        guard direction != 0 else { return }
        edgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled, let self else { return }
                self.scrollRequest = ScrollRequest(direction: direction)
            }
        }
    }

    func leave(rowId: String?, columnId: String) {
        if target?.columnId == columnId, target?.rowId == rowId { target = nil }
    }

    func end() {
        draggedRowId = nil
        target = nil
        edgeDirection = 0
        edgeTask?.cancel()
        edgeTask = nil
    }
}

private enum KanbanDrag {
    static let prefix = "docmost-base-row:"

    /// Dragged card's ID: from the state, else from the drag session's payload.
    static func draggedId(_ info: DropInfo, drag: KanbanDragState, completion: @escaping @MainActor @Sendable (String) -> Void) {
        if let id = drag.draggedRowId {
            completion(id)
            return
        }
        DragPayload.load(info, prefix: prefix, then: completion)
    }
}

/// Drop on a card (`rowId`): upper half inserts before it, lower half after; elsewhere in the column: appends.
private struct KanbanDropDelegate: DropDelegate {
    let model: BaseModel
    let columnId: String
    var rowId: String?
    var height: CGFloat = 0
    /// Board x of the drop area's leading edge; read only while dragging, so scrolling redraws no columns or cards.
    let boardMinX: () -> CGFloat
    let drag: KanbanDragState

    private func target(_ info: DropInfo) -> KanbanDropTarget {
        KanbanDropTarget(columnId: columnId, rowId: rowId, below: rowId != nil && info.location.y > height / 2)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: DragPayload.types) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag.leave(rowId: rowId, columnId: columnId)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = target(info)
        let model = model
        KanbanDrag.draggedId(info, drag: drag) { id in
            Task { await model.moveCard(id, to: target.columnId, beside: target.rowId, below: target.below) }
        }
        drag.end()
        return true
    }

    private func update(_ info: DropInfo) {
        drag.target = target(info)
        drag.hover(atBoardX: boardMinX() + info.location.x)
    }
}

// MARK: - Column

private struct KanbanColumnView: View {
    let model: BaseModel
    let column: BaseKanbanColumn
    let cardProperties: [BaseProperty]
    let drag: KanbanDragState
    let onOpen: (BaseRowRoute) -> Void
    @State private var minX: CGFloat = 0
    @State private var isCreating = false

    static let cardInset: CGFloat = 8

    private var countLabel: String {
        let count = column.list.rows.count
        return count > 99 || (column.list.hasMore && count >= 99) ? "99+" : "\(count)\(column.list.hasMore ? "+" : "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(column.list.rows) { row in
                            KanbanCard(
                                model: model, row: row, column: column, cardProperties: cardProperties, drag: drag,
                                boardMinX: { minX + Self.cardInset }, onOpen: onOpen
                            )
                            .onAppear {
                                if row.id == column.list.rows.last?.id { Task { await model.loadMore(columnId: column.id) } }
                            }
                        }
                        if drag.target == KanbanDropTarget(columnId: column.id, rowId: nil) {
                            InsertionMark()
                        }
                        if column.list.hasMore {
                            ProgressView().padding(8)
                        }
                        if column.list.rows.isEmpty {
                            Text("No entries")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                        }
                        if model.canEdit {
                            Button {
                                create(atTop: false)
                            } label: {
                                Label("New Entry", systemImage: "plus")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCreating)
                            .accessibilityIdentifier("base-column-add-\(column.id)")
                        }
                    }
                    .padding(.horizontal, Self.cardInset)
                    .padding(.bottom, 12)
                }
                .refreshable { await model.load() }
                .onChange(of: model.lastCreatedRowId) { _, rowId in
                    guard let rowId, column.list.rows.contains(where: { $0.id == rowId }) else { return }
                    withAnimation { proxy.scrollTo(rowId, anchor: .center) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView(axis: .horizontal)).minX } action: { minX = $0 }
        .onDrop(
            of: DragPayload.types,
            delegate: KanbanDropDelegate(model: model, columnId: column.id, boardMinX: { minX }, drag: drag)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("base-column-\(column.id)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let name = column.name {
                ChoicePill(choice: BaseChoice(id: column.id, name: name, color: column.color ?? "gray"))
            } else {
                Text("No value")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(countLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
            if model.canEdit {
                Button {
                    create(atTop: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isCreating)
                .accessibilityLabel("New Entry")
                .accessibilityIdentifier("base-column-new-\(column.id)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }

    /// Creates a card at the top ("+" in the header) or bottom ("New Entry"), then opens its detail sheet.
    private func create(atTop: Bool) {
        guard !isCreating else { return }
        isCreating = true
        Task {
            defer { isCreating = false }
            if let row = await model.createRow(inColumn: column.id, atTop: atTop) {
                onOpen(BaseRowRoute(rowId: row.id, focusTitle: true))
            }
        }
    }
}

// MARK: - Card

private struct KanbanCard: View {
    @Environment(AppSession.self) private var session
    let model: BaseModel
    let row: BaseRow
    let column: BaseKanbanColumn
    let cardProperties: [BaseProperty]
    let drag: KanbanDragState
    let boardMinX: () -> CGFloat
    let onOpen: (BaseRowRoute) -> Void
    @State private var height: CGFloat = 0
    @State private var confirmsDelete = false

    private var mark: KanbanDropTarget? {
        guard let target = drag.target, target.rowId == row.id, target.columnId == column.id else { return nil }
        return target
    }

    var body: some View {
        let card = Group {
            if KanbanCardHost.showsMenu {
                KanbanCardHost(
                    content: AnyView(button.environment(session)),
                    dragPayload: model.canEdit ? KanbanDrag.prefix + row.id : nil,
                    menu: menu,
                    onDragBegan: { drag.draggedRowId = row.id },
                    onDragEnded: { drag.end() }
                )
            } else if model.canEdit {
                // UI tests without the card menu: SwiftUI drag, which XCUITest can trigger (drop works as usual).
                button
                    .draggable(DragPayload.Item(payload: KanbanDrag.prefix + row.id))
                    .onDragSessionUpdated { session in
                        switch session.phase {
                        case .initial, .active: drag.draggedRowId = row.id
                        case .ended, .dataTransferCompleted: drag.end()
                        default: break
                        }
                    }
            } else {
                button
            }
        }

        .opacity(drag.draggedRowId == row.id ? 0.35 : 1)
        .overlay(alignment: mark?.below == true ? .bottom : .top) {
            if let mark {
                InsertionMark().offset(y: mark.below ? 5.5 : -5.5)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .deleteEntryConfirmation(isPresented: $confirmsDelete) { Task { await model.deleteRow(row.id) } }
        if model.canEdit {
            card.onDrop(
                of: DragPayload.types,
                delegate: KanbanDropDelegate(
                    model: model, columnId: column.id, rowId: row.id, height: height, boardMinX: boardMinX, drag: drag
                )
            )
        } else {
            card
        }
    }

    private var button: some View {
        Button {
            onOpen(BaseRowRoute(rowId: row.id))
        } label: {
            content
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("base-card-\(row.id)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            let title = model.base?.primaryProperty.flatMap { row.cells[$0.id]?.stringValue } ?? ""
            Text(title.isEmpty ? PageTitle.untitled : title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(title.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            ForEach(cardProperties) { property in
                if BaseLayout.hasValue(property, in: row) {
                    BaseCellView(property: property, row: row, users: model.users, pages: model.pages)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .contentShape(Rectangle())
    }

    /// Long-press menu (UIKit, because it must cooperate with dragging).
    private func menu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: String(localized: "Open"), image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [onOpen, row] _ in
                onOpen(BaseRowRoute(rowId: row.id))
            },
        ]
        if model.canEdit {
            let targets = model.columns.filter { $0.id != column.id }.map { target in
                UIAction(title: target.name ?? String(localized: "No value")) { [model, row] _ in
                    Task { await model.moveCard(row.id, to: target.id) }
                }
            }
            children.append(UIMenu(title: String(localized: "Move to"), image: UIImage(systemName: "arrow.right.square"), children: targets))
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: String(localized: "Delete Entry"), image: UIImage(systemName: "trash"), attributes: .destructive) { [confirmsDelete = $confirmsDelete] _ in
                    confirmsDelete.wrappedValue = true
                },
            ]))
        }
        return UIMenu(children: children)
    }
}

/// UIKit card wrapper (only while `showsMenu`): menu and drag on one view let iOS combine them as in Photos or Files
/// (hold: menu, move: drag). SwiftUI puts `.contextMenu` and `.draggable` on separate layers; the menu always wins.
private struct KanbanCardHost: UIViewControllerRepresentable {
    let content: AnyView
    /// Drag payload (`DragPayload`); `nil` = not draggable.
    let dragPayload: String?
    let menu: () -> UIMenu
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.sizingOptions = [.intrinsicContentSize]
        controller.view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        controller.view.addInteraction(UIDragInteraction(delegate: context.coordinator))
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<AnyView>, context: Context) {
        context.coordinator.parent = self
        controller.rootView = content
        for case let drag as UIDragInteraction in controller.view.interactions {
            drag.isEnabled = dragPayload != nil && Self.allowsDrag
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: proposal.width ?? 320, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// UI tests can disable the menu (`-base.cardMenu NO`): XCUITest doesn't perform the menu-to-drag transition,
    /// but without the menu its press-and-drag starts a real drag session.
    static var showsMenu: Bool {
        #if DEBUG
        // Launch arguments arrive as strings ("NO"): `bool(forKey:)` parses them, `as? Bool` doesn't.
        UserDefaults.standard.object(forKey: "base.cardMenu") == nil || UserDefaults.standard.bool(forKey: "base.cardMenu")
        #else
        true
        #endif
    }

    /// Menu UI tests disable dragging (`-base.cardDrag NO`): while the menu is open, iOS keeps the drag armed, and
    /// XCUITest then waits a minute per step for animations to finish.
    private static var allowsDrag: Bool {
        #if DEBUG
        UserDefaults.standard.object(forKey: "base.cardDrag") == nil || UserDefaults.standard.bool(forKey: "base.cardDrag")
        #else
        true
        #endif
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
        var parent: KanbanCardHost

        init(parent: KanbanCardHost) {
            self.parent = parent
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let menu = parent.menu
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedPreview(view: view, parameters: Self.rounded(view))
        }

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            guard let payload = parent.dragPayload else { return [] }
            return [UIDragItem(itemProvider: DragPayload.provider(payload))]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: any UIDragSession
        ) -> UITargetedDragPreview? {
            guard let view = interaction.view else { return nil }
            return UITargetedDragPreview(view: view, parameters: Self.rounded(view))
        }

        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
            parent.onDragBegan()
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            parent.onDragEnded()
        }

        private static func rounded(_ view: UIView) -> UIDragPreviewParameters {
            let parameters = UIDragPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 12)
            parameters.backgroundColor = .clear
            return parameters
        }
    }
}

/// Insertion mark between cards.
private struct InsertionMark: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}
