import SwiftUI
import DocmostKit

/// Grid like Notion and Airtable: scrolls both ways, the page header (`top`) scrolls away upward, column headers stay
/// pinned. Tapping a cell opens the detail sheet at its field; a long press shows the row actions.
struct BaseTableView<Top: View>: View {
    @Environment(AppSession.self) private var session
    let model: BaseModel
    let base: Base
    let view: BaseView
    @ViewBuilder let top: () -> Top
    let onOpen: (BaseRowRoute) -> Void
    @State private var confirmsDelete: BaseRow?

    static var rowHeight: CGFloat { 44 }

    var body: some View {
        ScrollViewReader { proxy in
            grid(BaseLayout.tableColumns(base: base, view: view))
                .onChange(of: model.lastCreatedRowId) { _, rowId in
                    // New row is last: scroll to it so it shows once the detail sheet closes.
                    guard let rowId, model.table.rows.contains(where: { $0.id == rowId }) else { return }
                    proxy.scrollTo(rowId, anchor: UnitPoint(x: 0, y: 0.5))
                }
        }
        .overlay {
            if model.table.rows.isEmpty && !model.isLoadingRows {
                if let error = model.rowsError {
                    ErrorStateView(error: error) { await model.load() }
                } else {
                    ContentUnavailableView("No entries", systemImage: "tablecells", description: Text("This view has no entries yet."))
                }
            }
        }
        .refreshable { await model.load() }
        .accessibilityIdentifier("base-table")
    }

    private func grid(_ columns: [BaseProperty]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Page header: visible width, fixed during horizontal scrolling.
                top()
                    .containerRelativeFrame(.horizontal, alignment: .leading)
                    .pinnedToLeadingEdge()
                Section {
                    ForEach(model.table.rows) { row in
                        rowView(row, columns: columns)
                            .id(row.id)
                            .onAppear {
                                if row.id == model.table.rows.last?.id { Task { await model.loadMoreTable() } }
                            }
                    }
                    if model.table.hasMore {
                        ProgressView()
                            .frame(height: Self.rowHeight)
                            .padding(.leading, 16)
                            .pinnedToLeadingEdge()
                    }
                } header: {
                    headerRow(columns)
                }
            }
            // Fixed width: otherwise the LazyVStack measures only children loaded so far (at first the screen-wide
            // page header) and the table can't scroll horizontally.
            .frame(width: columns.reduce(0) { $0 + BaseLayout.width(of: $1, in: view) }, alignment: .leading)
            .padding(.bottom, 40)
        }
    }

    private func headerRow(_ columns: [BaseProperty]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { property in
                Label(property.name, systemImage: BaseLayout.symbol(for: property.kind))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(width: BaseLayout.width(of: property, in: view), height: 36, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .overlay(alignment: .trailing) { gridLine(vertical: true) }
            }
        }
        .overlay(alignment: .bottom) { gridLine(vertical: false) }
    }

    private func rowView(_ row: BaseRow, columns: [BaseProperty]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { property in
                Button {
                    onOpen(BaseRowRoute(rowId: row.id, fieldId: property.isPrimary == true ? nil : property.id))
                } label: {
                    // Fixed frame: an empty cell would otherwise collapse to zero width.
                    Color(.systemBackground)
                        .frame(width: BaseLayout.width(of: property, in: view), height: Self.rowHeight)
                        .overlay(alignment: .leading) {
                            cell(property, row: row)
                                .padding(.horizontal, 10)
                        }
                        .clipped()
                        .overlay(alignment: .trailing) { gridLine(vertical: true) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("base-cell-\(property.id)")
            }
        }
        .overlay(alignment: .bottom) { gridLine(vertical: false) }
        .contentShape(.contextMenuPreview, Rectangle())
        .contextMenu {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
                onOpen(BaseRowRoute(rowId: row.id))
            }
            if model.canEdit {
                Divider()
                Button("Delete Entry", systemImage: "trash", role: .destructive) { confirmsDelete = row }
            }
        } preview: {
            rowPreview(row)
        }
        .deleteEntryConfirmation(isPresented: Binding { confirmsDelete?.id == row.id } set: { if !$0 { confirmsDelete = nil } }) {
            Task { await model.deleteRow(row.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("base-row-\(row.id)")
    }

    /// Long-press preview: title and first fields, not the whole wide row.
    private func rowPreview(_ row: BaseRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(BaseLayout.title(of: row, in: base))
                .font(.headline)
            ForEach(BaseLayout.tableColumns(base: base, view: view).filter { $0.isPrimary != true && BaseLayout.hasValue($0, in: row) }.prefix(4)) { property in
                VStack(alignment: .leading, spacing: 3) {
                    Text(property.name).font(.caption).foregroundStyle(.secondary)
                    BaseCellView(property: property, row: row, users: model.users, pages: model.pages)
                        .font(.subheadline)
                }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .environment(session)
    }

    @ViewBuilder
    private func cell(_ property: BaseProperty, row: BaseRow) -> some View {
        if property.isPrimary == true {
            let title = row.cells[property.id]?.stringValue ?? ""
            Text(title.isEmpty ? PageTitle.untitled : title)
                .font(.body.weight(.medium))
                .foregroundStyle(title.isEmpty ? .secondary : .primary)
                .lineLimit(1)
        } else {
            BaseCellView(property: property, row: row, users: model.users, pages: model.pages)
                .font(.subheadline)
        }
    }

    private func gridLine(vertical: Bool) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

private extension View {
    /// Keeps content at the left edge during horizontal scrolling (no layout change, so no stutter).
    func pinnedToLeadingEdge() -> some View {
        visualEffect { effect, proxy in
            effect.offset(x: max(0, -proxy.frame(in: .scrollView(axis: .horizontal)).minX))
        }
    }
}
