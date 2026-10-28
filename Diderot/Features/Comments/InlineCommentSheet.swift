import SwiftUI
import DocmostKit

/// New comment on the editor selection: creates it, then (as on the web) applies the `comment` mark with its ID.
/// The block stays active meanwhile (`DocumentModel.editsComment`) and gets focus back afterwards.
struct InlineCommentSheet: View {
    @Bindable var model: DocumentModel
    let comments: PageComments
    @Environment(\.dismiss) private var dismiss
    /// Where the selection starts, in characters: sending marks the quote's occurrence closest to it.
    @State private var offset: Int?
    @State private var quote = ""
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(quote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(Color.yellow).frame(width: 3)
                        }
                        .accessibilityIdentifier("inline-comment-quote")
                }
                Section {
                    TextField("Add a comment", text: $draft, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .accessibilityIdentifier("inline-comment-text")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Comment")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                // Not while sending: the comment would still be posted, its mark landing in whatever block is active
                // when the answer comes.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: send) {
                        if isSending { ProgressView() } else { Text("Send") }
                    }
                    .disabled(isSending || offset == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("inline-comment-send")
                }
            }
            .onAppear {
                if case .ranges(let ranges) = model.activeSelection.indices(in: model.activeText),
                   let first = ranges.ranges.first, let last = ranges.ranges.last, first.lowerBound < last.upperBound
                {
                    offset = model.activeText.characters.distance(from: model.activeText.startIndex, to: first.lowerBound)
                    quote = String(model.activeText[first.lowerBound..<last.upperBound].characters)
                }
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
        // Typed input closes only with Cancel, and never while sending.
        .interactiveDismissDisabled(isSending || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, let offset else { return }
        isSending = true
        errorMessage = nil
        Task {
            defer { isSending = false }
            do {
                // The server truncates the selection to 250 characters.
                let comment = try await comments.createInline(text: text, selection: String(quote.prefix(250)))
                if let range = Self.passage(quote, near: offset, in: model.activeText) {
                    model.activeText[range].docmost.comment = comment.id
                    model.activeText[range].docmost.commentResolved = nil
                    model.activeTextChanged()
                }
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// The occurrence of `quote` closest to `offset`: the selected one while the text is unchanged (its indices don't
    /// survive even an attribute change), the likeliest one after an edit; `nil` once the passage is gone.
    static func passage(_ quote: String, near offset: Int, in text: AttributedString) -> Range<AttributedString.Index>? {
        var best: (range: Range<AttributedString.Index>, distance: Int)?
        var start = text.startIndex
        while start < text.endIndex, let range = text[start...].range(of: quote) {
            let distance = abs(text.characters.distance(from: text.startIndex, to: range.lowerBound) - offset)
            if distance < best?.distance ?? .max { best = (range, distance) }
            start = text.characters.index(after: range.lowerBound)
        }
        return best?.range
    }
}
