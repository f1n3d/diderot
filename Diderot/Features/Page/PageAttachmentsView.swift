import SwiftUI
import DocmostKit

/// The files uploaded to a page, as the web lists them (Docmost 0.96): the newest first, searchable by name, with size,
/// date and who uploaded them. A file opens in Quick Look, which shares and saves it; from Docmost 0.97 on, space admins
/// who may edit the page delete one with a swipe, as on the web.
struct PageAttachmentsView: View {
    let page: Page
    let canDelete: Bool
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[Attachment]> = .idle
    @State private var query = ""
    /// The file being downloaded to open it.
    @State private var opening: String?
    @State private var preview: URL?
    @State private var deleting: Attachment?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            AsyncContentView(state: state, retry: { await load() }) { attachments in
                if attachments.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No attachments on this page yet.", systemImage: "paperclip")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(attachments) { attachment in
                        Button {
                            Task { await open(attachment) }
                        } label: {
                            AttachmentRow(attachment: attachment, isOpening: opening == attachment.id)
                        }
                        .disabled(opening != nil)
                        .swipeActions {
                            if canDelete {
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = attachment }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search attachments")
            .task(id: query) {
                // The server searches: wait for a pause in typing.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }
                await load()
            }
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .quickLookPreview($preview)
            .confirmationDialog(Text("Delete “\(deleting?.fileName ?? "")”?"), isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                                titleVisibility: .visible, presenting: deleting) { attachment in
                Button("Delete", role: .destructive) { Task { await delete(attachment) } }
            } message: { _ in
                Text("This can't be undone.")
            }
            // As in the comments: a failed download or delete says why below the list.
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        if state.value == nil { state = .loading }
        let search = query.trimmingCharacters(in: .whitespaces)
        do {
            let attachments = try await Paginated.all { cursor in
                try await session.perform {
                    try await client.send(Endpoints.Attachments.list(pageId: page.id, query: search.isEmpty ? nil : search, cursor: cursor))
                }
            }
            // A slower answer for an earlier query must not replace the current one.
            if search == query.trimmingCharacters(in: .whitespaces) { state = .loaded(attachments) }
        } catch is CancellationError {
        } catch {
            if state.value == nil { state = .failed(error) } else { errorMessage = error.userMessage }
        }
    }

    private func open(_ attachment: Attachment) async {
        guard let client = session.client,
              let url = RenderContext(session: session, pageId: page.id).mediaURL(attachment.fileURLPath) else { return }
        opening = attachment.id
        errorMessage = nil
        defer { opening = nil }
        do {
            let (data, _) = try await client.fetchFile(at: url)
            preview = try TempFile.write(data, folder: ["attachments", attachment.id], name: attachment.fileName)
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func delete(_ attachment: Attachment) async {
        guard let client = session.client else { return }
        errorMessage = nil
        do {
            _ = try await session.perform { try await client.send(Endpoints.Attachments.delete(attachmentId: attachment.id)) }
            if case .loaded(let attachments) = state {
                state = .loaded(attachments.filter { $0.id != attachment.id })
            }
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct AttachmentRow: View {
    let attachment: Attachment
    let isOpening: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isOpening { ProgressView() }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Size, date and who uploaded the file.
    private var details: String {
        var parts: [String] = []
        if let size = attachment.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        if let date = attachment.createdAt { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let name = attachment.creator?.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        let mime = attachment.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("tar") { return "doc.zipper" }
        if mime.contains("spreadsheet") || mime.contains("excel") || mime == "text/csv" { return "tablecells" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}
