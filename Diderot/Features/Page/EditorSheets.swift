import SwiftUI
import DocmostKit

/// Insert/edit sheets for status, math and embed links. An active block stays active and gets focus back afterwards.
struct EditorSheetView: View {
    let model: DocumentModel
    let sheet: EditorSheet

    var body: some View {
        switch sheet {
        case .status(let target, let text, let color):
            StatusSheet(model: model, target: target, text: text, color: color)
        case .mathInline(let target, let latex):
            MathSheet(model: model, kind: .inline(target), latex: latex)
        case .mathBlock(let slot, let latex):
            MathSheet(model: model, kind: .block(slot), latex: latex)
        case .embed(let slot, let provider, let link):
            EmbedSheet(model: model, slot: slot, provider: provider, link: link)
        }
    }
}

// MARK: - Status

/// Status as in the web client: short text and one of six colors.
private struct StatusSheet: View {
    let model: DocumentModel
    let target: EditorSheet.AtomTarget
    @State private var text: String
    @State private var color: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    static let colors: [(name: String, title: LocalizedStringKey)] = [
        ("gray", "Gray"), ("blue", "Blue"), ("green", "Green"), ("yellow", "Yellow"), ("red", "Red"), ("purple", "Purple"),
    ]

    init(model: DocumentModel, target: EditorSheet.AtomTarget, text: String, color: String) {
        self.model = model
        self.target = target
        _text = State(initialValue: text)
        _color = State(initialValue: color)
    }

    private var isEditing: Bool { if case .edit = target { true } else { false } }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(trimmed.isEmpty ? String(localized: "Status") : trimmed)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(StatusPalette.background(for: color), in: Capsule())
                        .foregroundStyle(StatusPalette.foreground(for: color))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                Section {
                    TextField("Status text", text: $text)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(apply)
                        .accessibilityIdentifier("status-text")
                }
                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(Self.colors, id: \.name) { option in
                            Button {
                                color = option.name
                            } label: {
                                Circle()
                                    .fill(StatusPalette.background(for: option.name))
                                    .overlay(Circle().strokeBorder(StatusPalette.foreground(for: option.name).opacity(0.6)))
                                    .overlay {
                                        if color == option.name {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(StatusPalette.foreground(for: option.name))
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(color == option.name ? .isSelected : [])
                            .accessibilityIdentifier("status-color-\(option.name)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if isEditing {
                    Section {
                        Button("Remove Status", role: .destructive) {
                            Task { await model.applyAtom(nil, type: "status", target: target) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Status")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Done" : "Insert", action: apply)
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("status-apply")
                }
            }
            .onAppear { focused = true }
        }
        // Full height from the start: at medium the keyboard covers the rest and the sheet then jumps up.
        .presentationDetents([.large])
    }

    private func apply() {
        guard !trimmed.isEmpty else { return }
        let node = PMNode(type: "status", attrs: ["text": .string(trimmed), "color": .string(color)])
        Task { await model.applyAtom(node, type: "status", target: target) }
        dismiss()
    }
}

// MARK: - Math

/// LaTeX equation with preview (KaTeX, as in the web client), inline or as a block.
private struct MathSheet: View {
    enum Kind {
        case inline(EditorSheet.AtomTarget)
        case block(EditorSheet.BlockSlot)
    }

    let model: DocumentModel
    let kind: Kind
    @State private var latex: String
    /// Debounced preview so it doesn't reload on every keystroke.
    @State private var preview: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(model: DocumentModel, kind: Kind, latex: String) {
        self.model = model
        self.kind = kind
        _latex = State(initialValue: latex)
        _preview = State(initialValue: latex)
    }

    private var isBlock: Bool { if case .block = kind { true } else { false } }
    private var isEditing: Bool {
        switch kind {
        case .inline(.edit), .block(.edit): true
        default: false
        }
    }
    private var trimmed: String { latex.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("LaTeX, e.g. E = mc^2", text: $latex, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...8)
                        .focused($focused)
                        .accessibilityIdentifier("math-latex")
                }
                Section("Preview") {
                    if preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Empty equation").foregroundStyle(.secondary)
                    } else {
                        WebIslandView(html: IslandHTML.math(preview, displayMode: isBlock), minHeight: 44)
                    }
                }
                if isEditing {
                    Section {
                        Button("Delete Equation", role: .destructive) {
                            finish(with: nil)
                        }
                    }
                }
            }
            .navigationTitle(isBlock ? "Math block" : "Math inline")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Done" : "Insert") { finish(with: trimmed) }
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("math-apply")
                }
            }
            .task(id: latex) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                preview = latex
            }
            .onAppear { focused = true }
        }
        // Full height from the start, as in StatusSheet.
        .presentationDetents([.large])
    }

    /// Applies the equation (`nil` deletes it).
    private func finish(with text: String?) {
        switch kind {
        case .inline(let target):
            let node = text.map { PMNode(type: "mathInline", attrs: ["text": .string($0)]) }
            Task { await model.applyAtom(node, type: "mathInline", target: target) }
        case .block(let slot):
            model.applyMathBlock(text, slot: slot)
        }
        dismiss()
    }
}

// MARK: - Embed

/// Embed link, validated as in the web client (the provider's pattern; any link for Iframe).
private struct EmbedSheet: View {
    let model: DocumentModel
    let slot: EditorSheet.BlockSlot
    let provider: EmbedProvider
    @State private var link: String
    @State private var isInvalid = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(model: DocumentModel, slot: EditorSheet.BlockSlot, provider: EmbedProvider, link: String) {
        self.model = model
        self.slot = slot
        self.provider = provider
        _link = State(initialValue: link)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Enter \(provider.name) link to embed"), text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(apply)
                        .accessibilityIdentifier("embed-link")
                } footer: {
                    if isInvalid {
                        Text("Invalid \(provider.name) embed link").foregroundStyle(.red)
                    } else {
                        Text("In the app the embed opens in the browser; on the web it is shown in the page.")
                    }
                }
            }
            // Provider name only: in German an "Embed …" title truncates between "Cancel" and "Embed link".
            .navigationTitle(provider.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Embed link", action: apply)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("embed-apply")
                }
            }
            .onChange(of: link) { _, _ in isInvalid = false }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private func apply() {
        guard let valid = provider.validated(link) else {
            isInvalid = true
            return
        }
        model.applyEmbed(provider: provider, link: valid, slot: slot)
        dismiss()
    }
}
