import SwiftUI
import DocmostKit

/// Appends a Markdown note to the end of the page; safe with concurrent web edits. What is typed stays on the device
/// until it is appended or cancelled (`NoteDraft`), and comes back when the sheet opens again for the page.
struct AppendNoteSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let page: Page
    var onAppended: () -> Void = {}

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// The session's place for the note, once the sheet has looked for one kept from before.
    @State private var draft: NoteDraft?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .focused($isFocused)
                        // Typed while the note goes out, it would go with neither the note nor the kept one.
                        .disabled(isSaving)
                        .accessibilityIdentifier("append-note-text")
                } header: {
                    Text("Markdown")
                } footer: {
                    Text("The note is added at the end of the page. Other people's edits are not affected.")
                }
                FormErrorSection(message: errorMessage)
            }
            .navigationTitle("Append Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: append) {
                        if isSaving { ProgressView() } else { Text("Append") }
                    }
                    .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            // The keyboard only once a note kept from before shows: typed before, it would be replaced.
            .task { await restore() }
            .onChange(of: text) { _, text in draft?.keep(text) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await draft?.keepNow(text) } }
            }
        }
        // Typed input closes only with Cancel; a swipe threw it away.
        .interactiveDismissDisabled(isSaving || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func restore() async {
        if let store = session.ready?.unsentChanges {
            let draft = NoteDraft(pageId: page.id, store: store)
            // Typed before the kept note arrived, both stay.
            if let kept = await draft.kept() { text = text.isEmpty ? kept : kept + "\n" + text }
            self.draft = draft
        }
        isFocused = true
    }

    private func cancel() {
        // Also before the sheet has looked for a kept note: cancelled, it would come back the next time.
        let draft = draft ?? session.ready.map { NoteDraft(pageId: page.id, store: $0.unsentChanges) }
        Task { await draft?.forget() }
        dismiss()
    }

    private func append() {
        // Both requests with this session: after a switch between them the note would go to the other server.
        guard let owner = session.ready, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                // Without Redis sync the page silently stays unchanged, so compare with the append's Markdown answer.
                // Not by block count: the server stores native edits ~10 s late, so new deletions could hide the note.
                let before = try await session.send(Endpoints.Pages.info(pageId: page.id, format: "markdown"), on: owner)
                let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let appended = try await session.send(Endpoints.Pages.appendMarkdown(pageId: page.id, note), on: owner)
                if appended.content == before.content {
                    errorMessage = String(localized: "The server accepted the note but the page did not change. Collaboration sync may be disabled on this server.")
                    return
                }
                await draft?.forget()
                onAppended()
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
