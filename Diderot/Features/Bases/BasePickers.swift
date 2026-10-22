import SwiftUI
import DocmostKit

// MARK: - Select, Status, Multi-Select

/// Choice list with search. Single select: a tap selects and goes back; tapping the selected value clears it.
/// Multi-select: a tap toggles, the list stays open. As on the web, status can't add options.
struct BaseChoicePicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: BaseModel
    let rowId: String
    let propertyId: String
    @State private var search = ""
    @State private var isSearching = false
    @State private var isAdding = false

    var body: some View {
        if let property = model.base?.property(id: propertyId), let row = model.row(id: rowId) {
            list(property: property, row: row)
                .navigationTitle(property.name)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "tablecells")
        }
    }

    private func list(property: BaseProperty, row: BaseRow) -> some View {
        let multiple = property.kind == .multiSelect
        let selected = Set(multiple ? BaseLayout.stringArray(row.cells[propertyId]) ?? [] : row.cells[propertyId]?.stringValue.map { [$0] } ?? [])
        let query = search.trimmingCharacters(in: .whitespaces)
        let all = BaseLayout.orderedChoices(of: property)
        let shown = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let canAdd = property.kind != .status && !query.isEmpty
            && !all.contains { $0.name.compare(query, options: [.caseInsensitive]) == .orderedSame }
        return List {
            if canAdd {
                Section {
                    Button {
                        Task { await add(query, property: property) }
                    } label: {
                        Label {
                            Text("Add Option “\(query)”")
                        } icon: {
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                    .disabled(isAdding)
                    .accessibilityIdentifier("base-add-option")
                }
            }
            if property.kind == .status {
                ForEach(statusGroups(shown), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.choices) { choice in
                            choiceRow(choice, selected: selected.contains(choice.id), multiple: false, row: row)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(shown) { choice in
                        choiceRow(choice, selected: selected.contains(choice.id), multiple: multiple, row: row)
                    }
                }
            }
            if shown.isEmpty && !canAdd {
                Text(all.isEmpty ? "No options yet" : "No matches")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(
            text: $search, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always),
            prompt: property.kind == .status ? Text("Search") : Text("Search or add option")
        )
    }

    private func choiceRow(_ choice: BaseChoice, selected: Bool, multiple: Bool, row: BaseRow) -> some View {
        Button {
            toggle(choice.id, multiple: multiple, row: row)
        } label: {
            HStack {
                ChoicePill(choice: choice)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("base-choice-\(choice.id)")
    }

    private func toggle(_ id: String, multiple: Bool, row: BaseRow) {
        let current = row.cells[propertyId]
        let value: JSONValue?
        if multiple {
            var ids = BaseLayout.stringArray(current) ?? []
            if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
            value = ids.isEmpty ? nil : .array(ids.map(JSONValue.string))
        } else {
            value = current?.stringValue == id ? nil : .string(id)
        }
        let rowId = rowId
        let propertyId = propertyId
        Task { await model.setCell(rowId: rowId, propertyId: propertyId, to: value) }
        if !multiple { dismiss() }
    }

    private func add(_ name: String, property: BaseProperty) async {
        isAdding = true
        defer { isAdding = false }
        guard let choice = await model.addChoice(named: name, to: property.id) else { return }
        // End the search so all options, including the new selected one, and the back button show again.
        search = ""
        isSearching = false
        guard let current = model.row(id: rowId) else { return }
        if property.kind == .multiSelect {
            let ids = (BaseLayout.stringArray(current.cells[propertyId]) ?? []) + [choice.id]
            await model.setCell(rowId: rowId, propertyId: propertyId, to: .array(ids.map(JSONValue.string)))
        } else {
            await model.setCell(rowId: rowId, propertyId: propertyId, to: .string(choice.id))
            dismiss()
        }
    }

    private struct StatusGroup {
        let title: String
        let choices: [BaseChoice]
    }

    /// Status grouped by category (web parity): To Do, In Progress, Complete (unknown last).
    private func statusGroups(_ choices: [BaseChoice]) -> [StatusGroup] {
        let known: [(String, String)] = [
            ("todo", String(localized: "To Do")),
            ("inProgress", String(localized: "In Progress")),
            ("complete", String(localized: "Complete")),
        ]
        var groups = known.compactMap { key, title -> StatusGroup? in
            let members = choices.filter { $0.category == key }
            return members.isEmpty ? nil : StatusGroup(title: title, choices: members)
        }
        let rest = choices.filter { choice in !known.contains { $0.0 == choice.category } }
        if !rest.isEmpty { groups.append(StatusGroup(title: String(localized: "Other"), choices: rest)) }
        return groups
    }
}

// MARK: - People

/// Workspace people via `search/suggest` (web parity). Single person: a tap selects and goes back; multiple: toggles.
struct BasePersonPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    let model: BaseModel
    let rowId: String
    let propertyId: String
    @State private var search = ""
    @State private var results: [SearchSuggestions.UserSuggestion] = []
    @State private var isLoading = false

    var body: some View {
        if let property = model.base?.property(id: propertyId), let row = model.row(id: rowId) {
            let multiple = BaseValue.allowsMultiplePeople(property)
            let selectedIds = BaseValue.personIds(row.cells[propertyId])
            List {
                if !selectedIds.isEmpty {
                    Section("Selected") {
                        ForEach(selectedIds, id: \.self) { id in
                            let user = model.users[id] ?? UserRef(id: id, name: nil, avatarUrl: nil)
                            personRow(id: id, name: user.name, email: nil, avatarUrl: user.avatarUrl, selected: true) {
                                set(selectedIds.filter { $0 != id }, multiple: multiple)
                            }
                        }
                    }
                }
                Section {
                    let others = results.filter { !selectedIds.contains($0.id) }
                    ForEach(others) { user in
                        personRow(id: user.id, name: user.name, email: user.email, avatarUrl: user.avatarUrl, selected: false) {
                            model.remember(user: UserRef(id: user.id, name: user.name, avatarUrl: user.avatarUrl))
                            set(multiple ? selectedIds + [user.id] : [user.id], multiple: multiple)
                            if !multiple { dismiss() }
                        }
                    }
                    if others.isEmpty && !isLoading {
                        Text("No people found").foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if isLoading && results.isEmpty { ProgressView() } }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search for a person"))
            .task(id: search) { await load() }
            .navigationTitle(property.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "tablecells")
        }
    }

    private func personRow(
        id: String, name: String?, email: String?, avatarUrl: String?, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AvatarView(name: name, avatarUrl: avatarUrl, baseURL: session.server?.url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name ?? String(localized: "Unknown"))
                    if let email {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("base-person-\(id)")
    }

    private func set(_ ids: [String], multiple: Bool) {
        let value = BaseValue.people(ids, multiple: multiple)
        let rowId = rowId
        let propertyId = propertyId
        Task { await model.setCell(rowId: rowId, propertyId: propertyId, to: value) }
    }

    private func load() async {
        // Debounce keystrokes (web client: 250 ms).
        if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        let found = await model.suggestPeople(search)
        guard !Task.isCancelled else { return }
        results = found
    }
}

// MARK: - Page

/// Picks a linked page; pages in the database's own space come first.
struct BasePagePicker: View {
    @Environment(\.dismiss) private var dismiss
    let model: BaseModel
    let rowId: String
    let propertyId: String
    @State private var search = ""
    @State private var results: [SearchSuggestions.PageSuggestion] = []
    @State private var isLoading = false

    var body: some View {
        if let property = model.base?.property(id: propertyId), let row = model.row(id: rowId) {
            let selectedId = row.cells[propertyId]?.stringValue
            List {
                if let selectedId {
                    Section {
                        let page = model.pages[selectedId]
                        HStack(spacing: 8) {
                            PageIconView(icon: page?.icon, size: 16)
                            Text(PageTitle.display(page?.title)).lineLimit(1)
                            Spacer()
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.accentColor)
                        }
                        Button("Remove Page Link", systemImage: "link.badge.minus", role: .destructive) {
                            set(nil)
                            dismiss()
                        }
                        .accessibilityIdentifier("base-remove-page")
                    }
                }
                Section {
                    ForEach(results.filter { $0.id != selectedId }) { page in
                        Button {
                            model.remember(page: PageRef(
                                id: page.id, slugId: page.slugId, title: page.title, icon: page.icon, spaceId: page.spaceId
                            ))
                            set(page.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                PageIconView(icon: page.icon, size: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(PageTitle.display(page.title)).lineLimit(1)
                                    if let space = page.space?.name {
                                        Text(space).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("base-page-\(page.id)")
                    }
                    if results.isEmpty && !isLoading {
                        Text("No pages found").foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if isLoading && results.isEmpty { ProgressView() } }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search pages"))
            .task(id: search) { await load() }
            .navigationTitle(property.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Entry not found", systemImage: "tablecells")
        }
    }

    private func set(_ pageId: String?) {
        let rowId = rowId
        let propertyId = propertyId
        Task { await model.setCell(rowId: rowId, propertyId: propertyId, to: pageId.map(JSONValue.string)) }
    }

    private func load() async {
        if !search.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        let found = await model.suggestPages(search)
        guard !Task.isCancelled else { return }
        results = found
    }
}
