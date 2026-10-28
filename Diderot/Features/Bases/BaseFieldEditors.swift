import PhotosUI
import QuickLook
import SwiftUI
import DocmostKit

/// One detail-sheet field, name above value. Formulas and system fields stay read-only: the server computes them.
struct BaseFieldRow: View {
    let model: BaseModel
    let row: BaseRow
    let property: BaseProperty
    let editable: Bool
    let onPick: (BaseFieldPicker) -> Void
    let onOpenPage: (PageRef) -> Void

    private var value: JSONValue? { row.cells[property.id] }

    var body: some View {
        if editable {
            editor
        } else {
            readOnly
        }
    }

    private var readOnly: some View {
        stacked { display(onOpenPage: onOpenPage) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("base-field-\(property.id)")
    }

    @ViewBuilder
    private var editor: some View {
        switch property.kind {
        case .checkbox:
            Toggle(isOn: Binding {
                value?.boolValue == true
            } set: { checked in
                Task { await model.setCell(rowId: row.id, propertyId: property.id, to: .bool(checked)) }
            }) {
                label
            }
            .accessibilityIdentifier("base-field-\(property.id)")
        case .select, .status, .multiSelect, .person:
            Button {
                onPick(property.kind == .person ? .people(property.id) : .choices(property.id))
            } label: {
                HStack {
                    stacked { display(onOpenPage: onOpenPage) }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("base-field-\(property.id)")
        case .page:
            HStack {
                Button {
                    onPick(.page(property.id))
                } label: {
                    // No tap action of its own: a tap opens the picker; the button next to it opens the page.
                    stacked { display() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("base-field-\(property.id)")
                if let id = value?.stringValue {
                    Button {
                        onOpenPage(model.pages[id] ?? PageRef(id: id))
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open Page")
                    .accessibilityIdentifier("base-open-page-\(property.id)")
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        case .text, .url, .email, .number, .longText, .date, .file:
            stacked { inlineEditor }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("base-field-\(property.id)")
        case .formula, .createdAt, .lastEditedAt, .lastEditedBy, nil:
            readOnly
        }
    }

    @ViewBuilder
    private var inlineEditor: some View {
        switch property.kind {
        case .longText: BaseLongTextEditor(model: model, rowId: row.id, property: property, stored: value)
        case .date: BaseDateEditor(model: model, rowId: row.id, property: property, stored: value)
        case .file: BaseFileEditor(model: model, rowId: row.id, property: property, stored: value)
        default: BaseTextFieldEditor(model: model, rowId: row.id, property: property, stored: value, displayRow: row)
        }
    }

    private var label: some View {
        Label(property.name, systemImage: BaseLayout.symbol(for: property.kind))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func stacked<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label
            content()
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    /// Read-only value (pills, people, formula …) or "—"; a linked page opens with `onOpenPage`.
    @ViewBuilder
    private func display(onOpenPage: ((PageRef) -> Void)? = nil) -> some View {
        if BaseLayout.hasValue(property, in: row) || property.kind == .checkbox || property.kind == nil {
            BaseCellView(property: property, row: row, users: model.users, pages: model.pages, style: .detail, onOpenPage: onOpenPage)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Text, URL, Email, Number

/// Single-line field; saves on losing focus or Return, if changed.
struct BaseTextFieldEditor: View {
    let model: BaseModel
    let rowId: String
    let property: BaseProperty
    let stored: JSONValue?
    let displayRow: BaseRow
    @State private var draft = ""
    @State private var original = ""
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var kind: BaseProperty.Kind? { property.kind }

    private var initialDraft: String {
        kind == .number ? BaseValue.numberDraft(stored?.doubleValue) : (stored?.stringValue ?? "")
    }

    private var linkURL: URL? {
        guard let text = stored?.stringValue, !text.isEmpty else { return nil }
        switch kind {
        case .url: return BaseValue.openURL(text)
        case .email: return URL(string: "mailto:\(text)")
        default: return nil
        }
    }

    /// An empty URL field shows the format the server expects (web parity).
    private var placeholder: String {
        kind == .url ? "https://…" : String(localized: "Empty")
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: kind == .text ? .vertical : .horizontal)
                .focused($focused)
                .keyboardType(keyboard)
                .textInputAutocapitalization(kind == .text ? .sentences : .never)
                .autocorrectionDisabled(kind != .text)
                .submitLabel(.done)
                .onSubmit { focused = false }
                // Unfocused, a number shows its format (currency, percent, progress); the field behind stays tappable.
                .foregroundStyle(showsFormattedNumber ? Color.clear : Color.primary)
                .overlay(alignment: .leading) {
                    if showsFormattedNumber {
                        BaseCellView(property: property, row: displayRow, users: [:], pages: [:], style: .detail)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(Text(property.name))
                .accessibilityIdentifier("base-input-\(property.id)")
            if let linkURL, !focused {
                Link(destination: linkURL) {
                    Image(systemName: kind == .email ? "envelope" : "arrow.up.right.square")
                }
                .accessibilityLabel(kind == .email ? Text("Send Email") : Text("Open Link"))
            }
        }
        .onAppear(perform: showStored)
        .onChange(of: draft) { _, text in
            // Text is single-line but wraps: Return ends the input.
            if kind == .text, text.contains("\n") {
                draft = text.replacingOccurrences(of: "\n", with: "")
                focused = false
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        .onChange(of: stored) { _, _ in
            guard !focused else { return }
            showStored()
        }
        .onDisappear { commit() }
        // Typed but not yet committed when the app leaves: iOS may end it in the background before the field loses focus.
        .onChange(of: scenePhase) { _, phase in if phase == .background, focused { commit() } }
    }

    /// The stored value, or the text a failed save didn't get to the server: it stays in the field, the next commit sends
    /// it again. A failed save used to put the old value back.
    private func showStored() {
        original = initialDraft
        draft = model.unsavedDraft(rowId: rowId, propertyId: property.id) ?? original
    }

    private var showsFormattedNumber: Bool {
        kind == .number && !focused && stored?.doubleValue != nil && draft == original
    }

    private var keyboard: UIKeyboardType {
        switch kind {
        // Digits with minus, comma and Return (`.decimalPad` has no minus key).
        case .number: .numbersAndPunctuation
        case .url: .URL
        case .email: .emailAddress
        default: .default
        }
    }

    private func commit() {
        guard draft != original else { return }
        let value: JSONValue?
        switch kind {
        case .number:
            switch BaseValue.parseNumber(draft) {
            case .clear: value = nil
            case .value(let number): value = BaseValue.number(number)
            case .invalid:
                draft = original
                model.toast = String(localized: "Not a number")
                return
            }
        case .url:
            value = BaseValue.url(draft)
        case .email:
            value = BaseValue.email(draft)
        default:
            value = BaseValue.text(draft)
        }
        original = draft
        let rowId = rowId
        let propertyId = property.id
        let typed = draft
        // Finished in the background too, when the app is leaving.
        let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            await model.setCell(rowId: rowId, propertyId: propertyId, to: value, typed: typed)
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

// MARK: - Long Text

/// Multi-line field; saves on losing focus (trimmed; empty clears the cell).
struct BaseLongTextEditor: View {
    let model: BaseModel
    let rowId: String
    let property: BaseProperty
    let stored: JSONValue?
    @State private var draft = ""
    @State private var original = ""
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TextField("Empty", text: $draft, axis: .vertical)
            .lineLimit(1...12)
            .focused($focused)
            .onAppear(perform: showStored)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: stored) { _, _ in
                guard !focused else { return }
                showStored()
            }
            .onDisappear { commit() }
            .onChange(of: scenePhase) { _, phase in if phase == .background, focused { commit() } }
            .accessibilityLabel(Text(property.name))
            .accessibilityIdentifier("base-input-\(property.id)")
    }

    /// The stored text, or the one a failed save didn't get to the server (see `BaseTextFieldEditor`).
    private func showStored() {
        original = stored?.stringValue ?? ""
        draft = model.unsavedDraft(rowId: rowId, propertyId: property.id) ?? original
    }

    private func commit() {
        guard draft != original else { return }
        original = draft
        let value = BaseValue.longText(draft)
        let rowId = rowId
        let propertyId = property.id
        let typed = draft
        // Finished in the background too, when the app is leaving.
        let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        Task {
            await model.setCell(rowId: rowId, propertyId: propertyId, to: value, typed: typed)
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

// MARK: - Date

/// Day picker with a remove button; no time even with "include time" (web parity).
struct BaseDateEditor: View {
    let model: BaseModel
    let rowId: String
    let property: BaseProperty
    let stored: JSONValue?

    var body: some View {
        if let date = BaseValue.pickerDate(stored) {
            HStack {
                DatePicker("Date", selection: Binding { date } set: { set($0) }, displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityIdentifier("base-date-\(property.id)")
                Spacer(minLength: 0)
                Button {
                    Task { await model.setCell(rowId: rowId, propertyId: property.id, to: nil) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove Date")
                .accessibilityIdentifier("base-clear-\(property.id)")
            }
        } else {
            Button("Add Date", systemImage: "calendar.badge.plus") { set(.now) }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("base-add-date-\(property.id)")
        }
    }

    private func set(_ date: Date) {
        let value = BaseValue.date(date)
        Task { await model.setCell(rowId: rowId, propertyId: property.id, to: value) }
    }
}

// MARK: - Files

/// Cell files: tap previews, minus removes; add from photos, camera or files.
struct BaseFileEditor: View {
    @Environment(AppSession.self) private var session
    let model: BaseModel
    let rowId: String
    let property: BaseProperty
    let stored: JSONValue?
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var previewURL: URL?
    @State private var downloading: Set<String> = []

    private struct FileEntry: Identifiable {
        let id: String
        let name: String
        let url: String?
        let size: Int?
    }

    private var files: [FileEntry] {
        (stored?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue else { return nil }
            return FileEntry(
                id: id, name: value["fileName"]?.stringValue ?? id, url: value["url"]?.stringValue, size: value["fileSize"]?.intValue
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files) { file in
                HStack(spacing: 10) {
                    Button {
                        Task { await open(file) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).lineLimit(2)
                                if let size = file.size {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if downloading.contains(file.id) { ProgressView().controlSize(.small) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("base-file-\(file.id)")
                    Button {
                        remove(file)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(file.name)"))
                    .accessibilityIdentifier("base-remove-file-\(file.id)")
                }
            }
            Menu {
                Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { showsCamera = true }
                }
                Button("Choose File", systemImage: "folder") { showsFileImporter = true }
            } label: {
                Label("Add File", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("base-add-file-\(property.id)")
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                do {
                    if let file = try await UploadFile.photo(item) { await upload(file) }
                } catch {
                    model.toast = error.localizedDescription
                }
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                Task { await upload(UploadFile.camera(data)) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        await upload(try await UploadFile.file(at: url))
                    } catch {
                        model.toast = error.localizedDescription
                    }
                }
            case .failure(let error):
                model.toast = error.localizedDescription
            }
        }
        .quickLookPreview($previewURL)
    }

    private func upload(_ file: UploadFile) async {
        await model.attachFile(rowId: rowId, propertyId: property.id, data: file.data, fileName: file.fileName, mimeType: file.mimeType)
    }

    private func remove(_ file: FileEntry) {
        let remaining = (stored?.arrayValue ?? []).filter { $0["id"]?.stringValue != file.id }
        Task { await model.setCell(rowId: rowId, propertyId: property.id, to: remaining.isEmpty ? nil : .array(remaining)) }
    }

    /// Downloads through the authenticated session, then shows Quick Look.
    private func open(_ file: FileEntry) async {
        guard let baseURL = session.server?.url, let client = session.client else { return }
        let path = file.url ?? "/api/files/\(file.id)/\(file.name)"
        guard let url = ImageURL.resolveContentMedia(path, baseURL: baseURL) else { return }
        // Each file keeps its spinner while another one loads too; a second tap doesn't load it again.
        guard downloading.insert(file.id).inserted else { return }
        defer { downloading.remove(file.id) }
        do {
            let (data, _) = try await client.fetchFile(at: url)
            previewURL = try TempFile.write(data, folder: ["attachments", file.id], name: file.name)
        } catch {
            model.toast = error.userMessage
        }
    }
}
