import SwiftUI
import DocmostKit

/// Month calendar as the web shows one on a phone (Docmost 0.98, Mantine's `MobileMonthView`): the month's six weeks
/// with a dot for each entry on the days it covers, at most three, and the chosen day's entries below them. Tapping a
/// day of the weeks around the month shows that month; tapping an entry opens it. The page header (`top`) scrolls away
/// with the calendar. Dragging entries and the week layout stay on the web, which offers neither on a phone.
struct BaseCalendarView<Top: View>: View {
    let model: BaseModel
    let base: Base
    let view: BaseView
    @ViewBuilder let top: () -> Top
    let onOpen: (BaseRowRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                top()
                Divider()
                if let property = BaseCalendarLayout.dateProperty(base: base, view: view) {
                    calendar(property)
                } else {
                    noDateProperty
                }
            }
        }
        .refreshable { await model.load() }
        .accessibilityIdentifier("base-calendar")
    }

    private func calendar(_ property: BaseProperty) -> some View {
        let month = model.calendarMonth
        let chosen = model.calendarDay
        let byDay = BaseCalendarLayout.entriesByDay(model.calendarEntries, in: month)
        return VStack(alignment: .leading, spacing: 12) {
            header(month)
            notices(property)
            if let error = model.rowsError {
                ErrorStateView(error: error) { await model.load() }
                    .padding(.vertical, 24)
            } else {
                BaseCalendarGrid(month: month, chosen: chosen, byDay: byDay) { choose($0) }
                dayList(chosen, entries: byDay[chosen] ?? [], property: property)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 40)
    }

    /// The month's name, then previous month, "Today" and next month, as on the web.
    private func header(_ month: BaseCalendarMonth) -> some View {
        HStack(spacing: 8) {
            Text(month.first.date, format: BaseCalendarStyle.days.month(.wide).year())
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("base-calendar-month")
            if model.isLoadingRows {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button("Previous month", systemImage: "chevron.left") { choose(month.first.adding(months: -1)) }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("base-calendar-previous")
            Button("Today") { choose(CalendarDay(containing: .now)) }
                .accessibilityIdentifier("base-calendar-today")
            Button("Next month", systemImage: "chevron.right") { choose(month.first.adding(months: 1)) }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("base-calendar-next")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// The server's limit cut the month's entries short; or it read their dates in another time zone than the device's.
    @ViewBuilder
    private func notices(_ property: BaseProperty) -> some View {
        if model.showsCalendarMonth {
            if model.calendar.truncated {
                Label("Showing the first \(Endpoints.Bases.calendarRowLimit) of \(model.calendar.total) entries in this range",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("base-calendar-truncated")
            }
            if let zone = BaseCalendarLayout.foreignTimeZone(
                model.calendar.timeZone, kind: BaseCalendarLayout.kind(of: property), filter: BaseLayout.filter(of: view)
            ) {
                Label("This calendar uses \(zone), not your time zone", systemImage: "globe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("base-calendar-time-zone")
            }
        }
    }

    private func dayList(_ day: CalendarDay, entries: [BaseCalendarEntry], property: BaseProperty) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.date, format: BaseCalendarStyle.days.weekday(.wide).month(.wide).day())
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("base-calendar-day-title")
            if entries.isEmpty {
                Text("No entries")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let cardProperties = BaseLayout.cardProperties(base: base, view: view)
                ForEach(entries) { entry in
                    BaseCalendarEntryRow(model: model, entry: entry, property: property, cardProperties: cardProperties, onOpen: onOpen)
                }
            }
        }
        .padding(.top, 8)
    }

    /// No date property, or one that is gone. Choosing it is view editing, which stays on the web.
    private var noDateProperty: some View {
        ContentUnavailableView {
            if BaseCalendarLayout.datePropertyId(of: view) == nil {
                Label("This calendar has no date property yet.", systemImage: "calendar")
            } else {
                Label("This calendar's date property is no longer available.", systemImage: "calendar")
            }
        } description: {
            Text("Entries will appear here once someone with edit access chooses a date property in the web editor.")
        }
        .padding(.vertical, 40)
        .accessibilityIdentifier("base-calendar-no-date")
    }

    private func choose(_ day: CalendarDay) {
        Task { await model.chooseCalendarDay(day) }
    }
}

/// Days as the calendar names them: in the Gregorian calendar, at midnight UTC as `CalendarDay` keeps them.
private enum BaseCalendarStyle {
    static var days: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, calendar: Calendar(identifier: .gregorian), timeZone: .gmt)
    }
}

/// The month's six weeks under the weekday names: each day's number, today's in the accent color and the chosen day's
/// on a filled circle, the weeks around the month and weekends dimmed, a dot below for each entry, at most three.
private struct BaseCalendarGrid: View {
    let month: BaseCalendarMonth
    let chosen: CalendarDay
    let byDay: [CalendarDay: [BaseCalendarEntry]]
    let onChoose: (CalendarDay) -> Void
    /// The day's circle grows with the text size, as far as seven fit beside each other on a phone.
    @ScaledMetric(relativeTo: .callout) private var circle: CGFloat = 34

    var body: some View {
        let today = CalendarDay(containing: .now)
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(month.days.prefix(7), id: \.self) { day in
                    Text(day.date, format: BaseCalendarStyle.days.weekday(.short))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(month.days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        dayCell(day, today: today)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: CalendarDay, today: CalendarDay) -> some View {
        let entries = byDay[day] ?? []
        let isChosen = day == chosen
        let isToday = day == today
        let inMonth = month.contains(day)
        return Button {
            onChoose(day)
        } label: {
            VStack(spacing: 3) {
                Text(day.date, format: BaseCalendarStyle.days.day())
                    .font(.callout.weight(isChosen || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(numberColor(day, isChosen: isChosen, isToday: isToday, inMonth: inMonth))
                    .frame(width: min(circle, 48), height: min(circle, 48))
                    .background {
                        if isChosen { Circle().fill(isToday ? Color.accentColor : Color(.label)) }
                    }
                HStack(spacing: 3) {
                    ForEach(entries.prefix(3)) { _ in
                        Circle()
                            .fill(Color.accentColor.opacity(inMonth ? 1 : 0.4))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(day.date, format: BaseCalendarStyle.days.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(entries.map { $0.title ?? PageTitle.untitled }.joined(separator: ", "))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("base-calendar-day-\(day.value)")
    }

    private func numberColor(_ day: CalendarDay, isChosen: Bool, isToday: Bool, inMonth: Bool) -> Color {
        if isChosen { return Color(.systemBackground) }
        if isToday { return .accentColor }
        if !inMonth { return Color(.tertiaryLabel) }
        // As on the web; which days are the weekend follows the device's region.
        return Calendar.current.isDateInWeekend(day.start(in: .current)) ? Color(.secondaryLabel) : Color(.label)
    }
}

/// An entry in the chosen day's list, like a board's card: its title, its time and the view's card fields.
private struct BaseCalendarEntryRow: View {
    let model: BaseModel
    let entry: BaseCalendarEntry
    let property: BaseProperty
    let cardProperties: [BaseProperty]
    let onOpen: (BaseRowRoute) -> Void

    var body: some View {
        Button {
            onOpen(BaseRowRoute(rowId: entry.rowId))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title ?? PageTitle.untitled)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.title == nil ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    // "Created" and "Last edited" have no formats of their own.
                    Text(BaseCalendarLayout.when(entry, options: property.kind == .date ? property.typeOptions : nil))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let row = model.row(id: entry.rowId) {
                        // A checkbox shows also unchecked, as on a board's cards.
                        ForEach(cardProperties) { field in
                            if field.kind == .checkbox || BaseLayout.hasValue(field, in: row) {
                                BaseCellView(property: field, row: row, users: model.users, pages: model.pages, namesCheckbox: true)
                                    .font(.caption)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("base-calendar-entry-\(entry.rowId)")
    }
}
