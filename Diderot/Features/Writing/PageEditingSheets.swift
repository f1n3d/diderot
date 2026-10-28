import SwiftUI
import DocmostKit

/// Appends a Markdown note to the end of the page; safe with concurrent web edits.
struct AppendNoteSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let page: Page
    var onAppended: () -> Void = {}

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 200)
                        .focused($isFocused)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: append) {
                        if isSaving { ProgressView() } else { Text("Append") }
                    }
                    .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        // Typed input closes only with Cancel; a swipe threw it away.
        .interactiveDismissDisabled(isSaving || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func append() {
        guard session.client != nil, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                // Without Redis sync the page silently stays unchanged, so compare with the append's Markdown answer.
                // Not by block count: the server stores native edits ~10 s late, so new deletions could hide the note.
                let before = try await session.send(Endpoints.Pages.info(pageId: page.id, format: "markdown"))
                let appended = try await session.send(Endpoints.Pages.appendMarkdown(pageId: page.id, text.trimmingCharacters(in: .whitespacesAndNewlines)))
                if appended.content == before.content {
                    errorMessage = String(localized: "The server accepted the note but the page did not change. Collaboration sync may be disabled on this server.")
                    return
                }
                onAppended()
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}
