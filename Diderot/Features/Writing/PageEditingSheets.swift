import SwiftUI
import DocmostKit

/// Appends a Markdown note to the end of the page; safe with concurrent web edits. What is typed stays on the device
/// until it is appended or cancelled (`NoteDraft`), and comes back when the sheet opens again for the page. Not to a page
/// with footnotes: Docmost's append puts the note after them, where the page can't hold it (`Page.hasFootnotes`).
struct AppendNoteSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let page: Page
    var onAppended: () -> Void = {}

    @State private var text = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// The page has footnotes, as far as the sheet knows: "Append" stays off, and the note stays kept. First from the
    /// page it opens for, so the reason shows at once, also offline; then from the server's page when it opens, when the
    /// app comes back, and just before appending.
    @State private var hasFootnotes: Bool
    /// The session's place for the note, once the sheet has looked for one kept from before.
    @State private var draft: NoteDraft?
    @FocusState private var isFocused: Bool

    init(page: Page, onAppended: @escaping () -> Void = {}) {
        self.page = page
        self.onAppended = onAppended
        _hasFootnotes = State(initialValue: page.hasFootnotes)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Above the note, where the keyboard leaves it in sight.
                FormErrorSection(message: hasFootnotes ? Self.footnotesNotice : nil)
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
                    if !hasFootnotes {
                        Text("The note is added at the end of the page. Other people's edits are not affected.")
                    }
                }
                FormErrorSection(message: errorMessage)
            }
            .task { await lookForFootnotes() }
            .task(id: hasFootnotes) {
                if hasFootnotes { AccessibilityNotification.Announcement(Self.footnotesNotice).post() }
            }
            .navigationTitle("Append Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel).disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: append) {
                        if isSaving { ProgressView() } else { Text("Append") }
                    }
                    .disabled(isSaving || hasFootnotes || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            // The keyboard only once a note kept from before shows: typed before, it would be replaced.
            .task { await restore() }
            .onChange(of: text) { _, text in draft?.keep(text) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { Task { await draft?.keepNow(text) } }
                // Footnotes may have come or gone meanwhile, as on the web.
                if phase == .active { Task { await lookForFootnotes() } }
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

    /// The server's page, where it can be had: a failed look leaves what the sheet knew, as it takes notes offline too,
    /// and appending looks again.
    private func lookForFootnotes() async {
        guard let owner = session.ready,
              let current = try? await session.send(Endpoints.Pages.info(pageId: page.id), on: owner) else { return }
        hasFootnotes = current.hasFootnotes
    }

    private static let footnotesNotice = String(localized: "This page has footnotes. Docmost would add the note after them, where the page can't take it. Write the note in the page instead.")

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
                // Last before appending, from the server: a collaborator may have added footnotes since the sheet looked.
                // Docmost's append can't be told to go before them, so this keeps the gap to the append's request.
                hasFootnotes = try await session.send(Endpoints.Pages.info(pageId: page.id), on: owner).hasFootnotes
                if hasFootnotes { return }
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
