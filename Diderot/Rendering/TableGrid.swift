import SwiftUI
import DocmostKit

/// Where a table's cells sit on its grid, as the web's tables (prosemirror-tables' `TableMap`) place them: each cell
/// takes the next columns of its row that no cell from a row above still covers, `colspan` columns wide and `rowspan`
/// rows tall (at most to the table's last row).
nonisolated struct TableGrid: Equatable, Sendable {
    /// A cell's rows `top..<bottom` and columns `left..<right`.
    struct Area: Equatable, Sendable {
        var top: Int
        var left: Int
        var bottom: Int
        var right: Int

        func contains(_ other: Area) -> Bool {
            top <= other.top && left <= other.left && other.bottom <= bottom && other.right <= right
        }

        func intersects(_ other: Area) -> Bool {
            top < other.bottom && other.top < bottom && left < other.right && other.left < right
        }

        func union(_ other: Area) -> Area {
            Area(top: min(top, other.top), left: min(left, other.left), bottom: max(bottom, other.bottom), right: max(right, other.right))
        }
    }

    /// Each row's cells, in order.
    let areas: [[Area]]
    let width: Int
    var height: Int { areas.count }
    /// A cell spans more than one row or column (by its attributes, also where the table ends first).
    let hasMergedCells: Bool

    init(spans: [[(columns: Int, rows: Int)]]) {
        // Columns that cells from rows above still cover: `columns` until (before) row `until`.
        var covered: [(columns: Range<Int>, until: Int)] = []
        var width = 0
        areas = spans.enumerated().map { row, cells in
            covered.removeAll { $0.until <= row }
            var column = 0
            let areas = cells.map { span in
                while let cover = covered.first(where: { $0.columns.contains(column) }) { column = cover.columns.upperBound }
                let area = Area(top: row, left: column, bottom: min(row + span.rows, spans.count), right: column + span.columns)
                if area.bottom > row + 1 { covered.append((area.left..<area.right, area.bottom)) }
                column = area.right
                return area
            }
            width = max(width, column, covered.map(\.columns.upperBound).max() ?? 0)
            return areas
        }
        self.width = width
        hasMergedCells = spans.joined().contains { $0.columns > 1 || $0.rows > 1 }
    }

    init(table: PMNode) {
        self.init(spans: table.children.map { $0.children.map { (ContentParser.colspan(of: $0), ContentParser.rowspan(of: $0)) } })
    }

    init(table: TableBlock) {
        self.init(spans: table.rows.map { $0.cells.map { ($0.colspan, $0.rowspan) } })
    }

    /// The cell (row, index in the row) covering a slot of the grid.
    func cell(row: Int, column: Int) -> (row: Int, index: Int)? {
        for (top, cells) in areas.enumerated() where top <= row {
            if let index = cells.firstIndex(where: { $0.intersects(Area(top: row, left: column, bottom: row + 1, right: column + 1)) }) {
                return (top, index)
            }
        }
        return nil
    }

    /// Whether a cell merges with its neighbor to the right or below, as the engine's `mergeRight` and `mergeDown` do:
    /// the rectangle around both takes in the cells inside it; no other cell may stick out of it.
    func canMerge(row: Int, index: Int, right: Bool) -> Bool {
        guard areas.indices.contains(row), areas[row].indices.contains(index) else { return false }
        let area = areas[row][index]
        let slot = right ? (row: area.top, column: area.right) : (row: area.bottom, column: area.left)
        guard slot.row < height, slot.column < width, let neighbor = cell(row: slot.row, column: slot.column) else { return false }
        let merged = area.union(areas[neighbor.row][neighbor.index])
        return !areas.joined().contains { $0.intersects(merged) && !merged.contains($0) }
    }
}

/// A table cell's area on its grid, for `TableGridLayout`.
nonisolated struct TableCellArea: LayoutValueKey {
    static let defaultValue: TableGrid.Area? = nil
}

/// Lays out table cells (each with its `TableCellArea`) on their grid: each column as wide as its widest cell, each row
/// as tall as its tallest; a cell spanning several widens or heightens them evenly where they fall short. Each cell
/// fills its whole area, so the borders line up.
struct TableGridLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let tracks = tracks(subviews)
        return CGSize(width: tracks.widths.reduce(0, +), height: tracks.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tracks = tracks(subviews)
        // Where each column and row starts.
        let xs = tracks.widths.reduce(into: [bounds.minX]) { $0.append($0.last! + $1) }
        let ys = tracks.heights.reduce(into: [bounds.minY]) { $0.append($0.last! + $1) }
        for subview in subviews {
            guard let area = subview[TableCellArea.self] else { continue }
            subview.place(at: CGPoint(x: xs[area.left], y: ys[area.top]),
                          proposal: ProposedViewSize(width: xs[area.right] - xs[area.left], height: ys[area.bottom] - ys[area.top]))
        }
    }

    private func tracks(_ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        let cells = subviews.compactMap { subview in subview[TableCellArea.self].map { (subview: subview, area: $0) } }
        return Self.tracks(areas: cells.map(\.area), width: { cells[$0].subview.sizeThatFits(.unspecified).width },
                           height: { cells[$0].subview.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height })
    }

    /// Column widths and row heights for cells in `areas`: `width(cell)` is a cell's own width, `height(cell, width)` its
    /// height at a width.
    static func tracks(areas: [TableGrid.Area], width: (Int) -> CGFloat, height: (Int, CGFloat) -> CGFloat) -> (widths: [CGFloat], heights: [CGFloat]) {
        var widths = Array(repeating: CGFloat(0), count: areas.map(\.right).max() ?? 0)
        var heights = Array(repeating: CGFloat(0), count: areas.map(\.bottom).max() ?? 0)
        // Single cells first: what their columns (rows) already have counts toward a cell spanning them.
        for cell in areas.indices.sorted(by: { areas[$0].right - areas[$0].left < areas[$1].right - areas[$1].left }) {
            grow(&widths, areas[cell].left..<areas[cell].right, to: width(cell))
        }
        for cell in areas.indices.sorted(by: { areas[$0].bottom - areas[$0].top < areas[$1].bottom - areas[$1].top }) {
            let area = areas[cell]
            grow(&heights, area.top..<area.bottom, to: height(cell, widths[area.left..<area.right].reduce(0, +)))
        }
        return (widths, heights)
    }

    /// Widens `range` of `tracks` evenly until together they have `size`.
    private static func grow(_ tracks: inout [CGFloat], _ range: Range<Int>, to size: CGFloat) {
        let missing = size - tracks[range].reduce(0, +)
        guard missing > 0, !range.isEmpty else { return }
        for index in range { tracks[index] += missing / CGFloat(range.count) }
    }
}
