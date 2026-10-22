import SwiftUI
import DocmostKit

/// A page's comments as in the web client: open and resolved tabs, indented replies, inline comments with their
/// selected text. Edit only for own comments, delete also for space admins (as on the web); resolving is a licensed
/// feature.
struct CommentsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let page: Page
    let comments: PageComments
    /// May write, reply and resolve (the page view's rule).
    let canComment: Bool
    /// Space admins may delete others' comments too.
    var isSpaceAdmin = false
    /// Comment to scroll to on open (tap on a highlighted passage).
    var focusId: String?
    /// Shows a comment's passage on the page.
    var onShowInPage: ((PageComment) -> Void)?

    private enum Tab: Hashable { case open, resolved }
    private enum Composing: Equatable {
        case new
        case reply(PageComment)
        case edit(PageComment)
    }

    @State private var tab = Tab.open
    @State private var draft = ""
    @State private var composing = Composing.new
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var highlighted: String?
    @State private var confirmsDelete: PageComment?
    @FocusState private var composerFocused: Bool

    private var currentUserId: String? { session.ready?.currentUser.user.id }

    var body: some View {
        NavigationStack {
            AsyncContentView(state: comments.state, retry: { await comments.load() }) { _ in
                content
            }
            .safeAreaInset(edge: .bottom) {
                composer
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("comments-done")
                }
            }
            .environment(\.renderContext, RenderContext(session: session, pageId: page.id))
            .task { if comments.state.value == nil { await comments.load() } }
        }
        .accessibilityIdentifier("comments-sheet")
    }

    @ViewBuilder
    private var content: some View {
        let open = comments.threads.filter { !$0.isResolved }
        let resolved = comments.threads.filter(\.isResolved)
        let shown = tab == .open ? open : resolved
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Comments", selection: $tab) {
                        Text("Open \(open.count)").tag(Tab.open)
                        Text("Resolved \(resolved.count)").tag(Tab.resolved)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("comments-tabs")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                if shown.isEmpty {
                    Section {
                        ContentUnavailableView(
                            tab == .open ? "No open comments" : "No resolved comments", systemImage: "bubble.left.and.bubble.right",
                            description: tab == .open ? Text("Comments on this page will show up here.") : nil
                        )
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(shown) { thread in
                    Section {
                        row(thread)
                        ForEach(comments.replies(to: thread)) { reply in
                            row(reply)
                                .padding(.leading, 28)
                        }
                    }
                    .id(thread.id)
                    .listRowBackground(highlighted == thread.id ? Color.accentColor.opacity(0.14) : nil)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await comments.load() }
            .task(id: focusId) {
                // Tapped passage: show its thread (even if resolved), briefly highlighted.
                guard let focusId, let comment = comments.comment(id: focusId) else { return }
                let thread = comment.parentCommentId.flatMap { comments.comment(id: $0) } ?? comment
                tab = thread.isResolved ? .resolved : .open
                try? await Task.sleep(for: .milliseconds(250))
                withAnimation {
                    proxy.scrollTo(thread.id, anchor: .top)
                    highlighted = thread.id
                }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.6)) { highlighted = nil }
            }
        }
    }

    private func row(_ comment: PageComment) -> some View {
        // Same conditions as menu(for:), so "…" never opens an empty menu.
        CommentRow(comment: comment, baseURL: session.server?.url,
                   showsMenu: (canComment && !comment.isReply) || comment.creatorId == currentUserId || isSpaceAdmin,
                   confirmsDelete: Binding { confirmsDelete?.id == comment.id } set: { if !$0 { confirmsDelete = nil } },
                   onDelete: { run { try await comments.delete(comment) } }) {
            if comment.isInline, onShowInPage != nil {
                Button {
                    dismiss()
                    onShowInPage?(comment)
                } label: {
                    Label("Show on Page", systemImage: "text.viewfinder")
                }
            }
        } menu: {
            menu(for: comment)
        }
    }

    @ViewBuilder
    private func menu(for comment: PageComment) -> some View {
        if canComment, !comment.isReply {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(.reply(comment), text: "") }
        }
        if comment.creatorId == currentUserId {
            Button("Edit", systemImage: "pencil") { compose(.edit(comment), text: CommentContent.plainText(of: comment.content)) }
        }
        if comments.canResolve, canComment, !comment.isReply {
            if comment.isResolved {
                Button("Reopen", systemImage: "arrow.uturn.backward.circle") { run { try await comments.setResolved(comment, false) } }
            } else {
                Button("Resolve", systemImage: "checkmark.circle") { run { try await comments.setResolved(comment, true) } }
            }
        }
        if comment.creatorId == currentUserId || isSpaceAdmin {
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = comment }
        }
    }

    @ViewBuilder
    private var composer: some View {
        // Without comment rights it still shows for editing own comments and for errors (e.g. from Delete).
        if canComment || composing != .new || errorMessage != nil {
            VStack(spacing: 6) {
                if composing != .new {
                    HStack {
                        Group {
                            switch composing {
                            case .reply(let comment): Text("Replying to \(comment.creator?.name ?? String(localized: "comment"))")
                            case .edit: Text("Editing comment")
                            case .new: EmptyView()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { compose(.new, text: "") }
                            .font(.caption)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($composerFocused)
                        .accessibilityIdentifier("comments-composer")
                    Button(action: send) {
                        if isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill").font(.title2)
                        }
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("comments-send")
                }
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    private var placeholder: LocalizedStringKey {
        switch composing {
        case .new: "Add a comment"
        case .reply: "Write a reply"
        case .edit: "Edit comment"
        }
    }

    private func compose(_ mode: Composing, text: String) {
        composing = mode
        draft = text
        errorMessage = nil
        composerFocused = mode != .new
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        let mode = composing
        isSending = true
        errorMessage = nil
        Task {
            defer { isSending = false }
            do {
                switch mode {
                case .new: try await comments.create(text: text, replyTo: nil)
                case .reply(let comment): try await comments.create(text: text, replyTo: comment)
                case .edit(let comment): try await comments.update(comment, text: text)
                }
                compose(.new, text: "")
                composerFocused = false
                if case .new = mode { tab = .open }
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

private struct CommentRow<Actions: View, MenuItems: View>: View {
    let comment: PageComment
    let baseURL: URL?
    let showsMenu: Bool
    /// Delete confirmation; on the "…" because iOS shows it as a popover from the view it's attached to.
    @Binding var confirmsDelete: Bool
    let onDelete: () -> Void
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(name: comment.creator?.name, avatarUrl: comment.creator?.avatarUrl, baseURL: baseURL, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.creator?.name ?? String(localized: "Unknown")).font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        if let createdAt = comment.createdAt {
                            Text(createdAt, format: .relative(presentation: .named))
                        }
                        if comment.editedAt != nil {
                            Text("· edited")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if comment.isResolved {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                if showsMenu {
                    Menu {
                        menu()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("comment-menu-\(comment.id)")
                    .confirmationDialog("Delete comment?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                }
            }
            if comment.isInline, let selection = comment.selection, !selection.isEmpty {
                Text(selection)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.yellow).frame(width: 3)
                    }
                    .lineLimit(3)
            }
            BlockStack(blocks: ContentDocument(json: comment.content).blocks, spacing: 6)
                .font(.body)
            actions()
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .opacity(comment.isResolved ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comment-\(comment.id)")
    }
}
