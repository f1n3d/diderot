import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import DocmostKit

/// Reading and editing in one view: a tapped text block becomes an editor and changes go live through the engine;
/// read-only without write permission, in the trash, or offline.
struct PageView: View {
    @Environment(AppSession.self) private var session
    @Environment(ReaderNavigation.self) private var navigation
    @Environment(FavoritesStore.self) private var favorites
    @Environment(RecentlyOpenedStore.self) private var recentlyOpened
    @Environment(ContentChanges.self) private var changes
    @Environment(OfflineMonitor.self) private var offline
    @Environment(SpacesStore.self) private var spaces
    @Environment(AppNotices.self) private var notices
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// Between `onAppear` and `onDisappear`: not under a pushed page or in another tab.
    @State private var isOnScreen = false
    let selection: PageSelection

    @State private var state: LoadState<Page> = .idle
    @State private var model: DocumentModel?
    @State private var breadcrumbs: [Breadcrumb] = []
    @State private var position = ScrollPosition(edge: .top)
    @State private var toast: String?
    @State private var titleEdit = PageTitleEdit()
    @FocusState private var titleFocused: Bool
    /// The session the page loaded in: an edited title waits in its store when that session ends (401) or a link switches
    /// to another server, as the page's text does.
    @State private var pageSession: ReadySession?
    // A debug launch opens the web layout or a sheet at once (`DOCMOST_DEBUG_WEB`, `DOCMOST_DEBUG_ROUTE`).
    #if DEBUG
    private static var launchesWebLayout: Bool { DebugLaunch.webLayout }
    private static var launchRoute: String? { DebugLaunch.route }
    #else
    private static let launchesWebLayout = false
    private static let launchRoute: String? = nil
    #endif
    @State private var showsWebLayout = PageView.launchesWebLayout
    @State private var webHTML: String?
    @State private var showsComments = PageView.launchRoute == "comments"
    @State private var comments: PageComments?
    /// Comment the sheet jumps to on open (tap on a highlighted passage).
    @State private var commentsFocusId: String?
    /// A link's comment, shown once the page has pushed in: a sheet asked for mid-push doesn't show.
    @State private var pendingCommentId: String?
    /// A new page's title takes the cursor once the page has pushed in: focus asked for mid-push is dropped.
    @State private var focusesTitle = false
    /// Block a comment's passage is in ("Show on Page"), scrolled to once the comments are gone.
    @State private var revealsAnchor: String?
    /// A web page in the in-app browser (an integration mention's link).
    @State private var browsing: URL?
    /// The page's space; its settings say whether readers may comment.
    @State private var space: Space?
    @State private var showsHistory = PageView.launchRoute == "history"
    @State private var showsEmojiPicker = false
    @State private var showsAppendNote = false
    @State private var showsWebEditor = PageView.launchRoute == "webeditor"
    @State private var showsArrange = false
    /// The page for the presentation mode, as it was when it opened (as on the web).
    @State private var presentation: Presentation?
    @State private var showsAttachments = false
    @State private var confirmsTrash = false
    @State private var showsPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    /// Height of the page view below the navigation bar (ignoring the keyboard); sizes the trailing space.
    @State private var scrollHeight: CGFloat = 0
    @State private var find = PageFind()
    /// The templates for an empty page ("Get started with").
    @State private var showsTemplates = false
    #if DEBUG
    /// Test hook: counts full keyboard dismissals so UI tests can check the keyboard stays up across block switches.
    @State private var debugKeyboardHides = 0
    @State private var appliedDebugHooks = false
    #endif

    /// Content with navigation bar, toolbars and floating buttons.
    private var chrome: some View {
        AsyncContentView(state: state, retry: { await load(force: true) }) { page in
            Group {
                if page.isBase == true {
                    baseDocument(page)
                } else if showsWebLayout, let webHTML, let serverURL = session.server?.url {
                    WebLayoutView(html: webHTML, title: page.displayTitle, serverURL: serverURL, token: session.ready?.token)
                        .handlesLinks(handle)
                } else {
                    document(page)
                }
            }
            .background {
                AfterTransition {
                    guard let commentId = pendingCommentId else { return }
                    pendingCommentId = nil
                    openComments(focus: commentId)
                }
            }
        }
        .environment(\.renderContext, RenderContext(session: session, pageId: state.value?.id))
        .environment(\.linkPreviews, session.linkPreviews)
        .navigationTitle(state.value?.displayTitle ?? selection.title ?? "")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            if let model {
                // Own capsule without glass: inside the shared glass group the pill sits askew at the left edge.
                ToolbarItem(placement: .topBarTrailing) {
                    StatusPill(model: model, compact: horizontalSizeClass == .compact)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let model {
                    ForEach(model.participants.prefix(2)) { participant in
                        AvatarView(name: participant.name, avatarUrl: participant.avatarUrl, baseURL: session.server?.url, size: 22)
                    }
                }
                if let comments {
                    Button {
                        openComments(focus: nil)
                    } label: {
                        Label("Comments", systemImage: "bubble.left.and.bubble.right")
                    }
                    .badge(comments.openCount)
                    .accessibilityIdentifier("page-comments")
                }
                pageMenu
            }
            ToolbarItemGroup(placement: .keyboard) {
                if let model, model.active != nil {
                    EditorToolbar(model: model)
                }
            }
        }
        .overlay {
            if let model, model.uploads > 0 {
                ProgressView("Uploading…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if model?.isCreatingBase == true {
                ProgressView("Creating database…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Hidden, not removed, while editing: removing it while its menu still fades out makes SwiftUI rebuild the
            // view and re-parent the focused editor, which loses focus.
            if let model, model.isEditable, !showsWebLayout {
                let hidden = model.active != nil || find.isShown
                Menu {
                    AddBlockMenuContent(model: model)
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .padding(20)
                .accessibilityLabel("Add block")
                .accessibilityIdentifier("page-add-block")
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden)
                .accessibilityHidden(hidden)
            }
        }
    }

    /// The page's sheets, full-screen covers and pickers.
    private var presentations: some View {
        chrome
        .opensExternalLinks()
        .confirmationDialog("Paste As", isPresented: Binding { model?.pastedLink != nil } set: { if !$0 { model?.finishPastedLink(nil) } },
                            titleVisibility: .visible, presenting: model?.pastedLink) { link in
            if link.base != nil {
                Button("Inline Database") { model?.finishPastedLink(.embeddedBase) }
                Button("Mention") { model?.finishPastedLink(.mention) }
            } else {
                if link.allowsBlock { Button("Card") { model?.finishPastedLink(.card) } }
                Button("Mention") { model?.finishPastedLink(.mention) }
                Button("URL") { model?.finishPastedLink(.link) }
            }
        } message: { link in
            Text(link.url.absoluteString)
        }
        .linkSheet(item: $browsing) { url in
            SafariView(url: url).ignoresSafeArea()
        }
        .confirmationDialog("Link", isPresented: Binding { model?.mentionActions != nil } set: { if !$0 { model?.mentionActions = nil } },
                            titleVisibility: .hidden, presenting: model?.mentionActions) { target in
            if let url = target.webURL {
                Button("Open Link") { browsing = url }
            }
            if target.canShowAsCard {
                Button("Show as Card") { Task { await model?.showMention(target, as: .card) } }
            }
            Button("Show as URL") { Task { await model?.showMention(target, as: .link) } }
            Button("Remove", role: .destructive) {
                Task { await model?.replaceAtom(ofType: "integrationMention", in: target.ref, index: target.index, with: nil) }
            }
        }
        .linkSheet(isPresented: $showsComments, onDismiss: dismissedComments) {
            if let page = state.value, let comments {
                CommentsView(page: page, comments: comments, canComment: canComment(on: page),
                             isSpaceAdmin: spaces.state.value?.first { $0.id == page.spaceId }?.role == .admin,
                             focusId: commentsFocusId, onShowInPage: { showInPage($0) },
                             onDeleted: { comment in
                                 // Only an inline comment marks a passage.
                                 if comment.isInline { await model?.removeMarks(ofComment: comment.id) }
                             })
                .handlesLinks { url, outside in
                    // Pages and anchors open on the page, so the comments make way; web links open over them.
                    switch LinkTarget.of(url, serverURL: session.server?.url) {
                    case .page, .anchor:
                        showsComments = false
                        handle(url, outside: outside)
                    case .none: break
                    case .outside(let external): outside(external)
                    }
                }
            }
        }
        .linkSheet(isPresented: Binding(get: { model?.editsComment ?? false }, set: { model?.editsComment = $0 })) {
            if let model, let comments { InlineCommentSheet(model: model, comments: comments) }
        }
        .linkSheet(isPresented: $showsHistory) {
            if let page = state.value { HistoryView(page: page) }
        }
        .linkSheet(isPresented: $showsAppendNote) {
            if let page = state.value {
                AppendNoteSheet(page: page) { Task { await load(force: true) } }
            }
        }
        .linkSheet(isPresented: $showsArrange) {
            if let model { ArrangeSheet(model: model) }
        }
        .linkSheet(isPresented: $showsAttachments) {
            if let page = state.value { PageAttachmentsView(page: page, canDelete: canDeleteAttachments(of: page)) }
        }
        .linkSheet(isPresented: Binding(get: { model?.editsLink ?? false }, set: { model?.editsLink = $0 })) {
            if let model { LinkSheet(model: model) }
        }
        .linkSheet(item: Binding(get: { model?.editorSheet }, set: { model?.editorSheet = $0 }), onDismiss: { model?.editorSheetDismissed() }) { sheet in
            if let model { EditorSheetView(model: model, sheet: sheet) }
        }
        .linkFullScreenCover(isPresented: $showsWebEditor) {
            if let page = state.value, let serverURL = session.server?.url, let token = session.ready?.token {
                WebEditorView(page: page, serverURL: serverURL, token: token) {
                    Task { await load(force: true) }
                    changes.pageChanged(in: page.spaceId)
                }
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: nil,
                      matching: model?.pendingMedia?.action == .videos ? .videos : .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let model else { return }
            let target = model.takeMediaTarget()
            photoItems = []
            model.upload(items.count, to: target) { try await UploadFile.photo(items[$0], server: $1) }
        }
        .linkFullScreenCover(item: $presentation) { presentation in
            PresentationView(pageId: presentation.pageId, title: presentation.title, document: presentation.document) { url in
                handle(url, outside: OpenURLAction { _ in .discarded })
            }
        }
        .linkFullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                guard let model else { return }
                let target = model.takeMediaTarget()
                model.upload(1, to: target) { try UploadFile.camera(data, server: $1) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard let model else { return }
                let target = model.takeMediaTarget()
                model.upload(urls.count, to: target) { try await UploadFile.file(at: urls[$0], server: $1) }
            case .failure(let error):
                toast = error.userMessage
                model?.cancelMedia()
            }
        }
        .onChange(of: model?.pendingMedia?.id) { _, _ in
            switch model?.pendingMedia?.action {
            case .images, .videos:
                showsPhotoPicker = true
            case .camera:
                // Offered only with a camera (`availableCommands`).
                showsCamera = true
            case .audio, .pdf, .attachment:
                showsFileImporter = true
            case nil: break
            }
        }
        .onChange(of: model?.requestsWebEditor) { _, requested in
            guard requested == true else { return }
            model?.requestsWebEditor = false
            showsWebEditor = true
        }
        .onChange(of: model?.notice) { _, notice in
            guard let notice else { return }
            toast = notice
            model?.notice = nil
        }
        .background {
            // "/emoji": the iOS emoji keyboard takes over; the chosen emoji is inserted at the cursor.
            EmojiPickerField(isPresented: Binding(get: { model?.editsEmoji ?? false }, set: { if !$0 { model?.finishEmoji(nil) } }),
                             identifier: "insert-emoji-field") { emoji in
                model?.finishEmoji(emoji)
            }
            .frame(width: 1, height: 1)
        }
    }

    var body: some View {
        presentations
        .toast($toast)
        // Refreshes on every appearance, as the web does: coming back to a page deleted or unshared meanwhile shows that
        // instead of its old content, and a refresh cancelled by opening a subpage runs again.
        .task(id: selection.pageId) { await load(force: state.value != nil) }
        .task(id: state.value?.id) { await showUnsentTitle() }
        #if DEBUG
        .onChange(of: model?.isLive) { _, live in
            if let model, live == true, !appliedDebugHooks {
                appliedDebugHooks = true
                Task { await model.applyDebugHooks() }
            }
        }
        #endif
        .onChange(of: showsWebLayout) { _, enabled in
            if enabled { Task { await loadWebHTML() } }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
        // Back online: a page opened offline (read-only) becomes editable by itself; before, it stayed read-only until
        // pulled down or opened again.
        .onChange(of: offline.isOffline) { _, isOffline in
            if !isOffline, model?.readOnlyReason == .offline { Task { await load(force: true) } }
        }
        .onChange(of: titleEdit.text) { _, _ in
            if titleEdit.takeReturn() { titleFocused = false }
        }
        .onAppear {
            isOnScreen = true
            registerSelectionCommands()
            model?.resume()
        }
        // Back in the app: an editor that failed to open, or whose web process ended while opening, tries again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isOnScreen { model?.resume() }
            // iOS may end the app in the background, and an app swiped away in the app switcher never gets there: keep
            // unsent changes as leaving the page would. A title being typed goes too (kept first, see `commitTitle`), also
            // on a database page.
            if phase != .active {
                let savingTitle = phase == .background && titleFocused ? commitTitle() : nil
                BackgroundWork.run("Keep unsent changes") {
                    await model?.saveUnsentChanges()
                    await savingTitle?.value
                }
            }
        }
        .onDisappear {
            isOnScreen = false
            // The page can leave while its title still has focus (no `onChange` then): save the edit, like the web.
            if titleFocused { commitTitle() }
            if let model, EditorSelectionCommands.model === model { EditorSelectionCommands.model = nil }
            // The camera's full-screen cover is the page's own picker: the page stays live under it, for the photo.
            if showsCamera { model?.deactivate() } else { model?.leave() }
        }
        // No automatic keyboard avoidance (it jumps before centering runs); `CentersAboveKeyboard` handles the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Find bar outside of that: it sits above the keyboard and the document gets bottom space for it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if find.isShown {
                PageFindBar(find: find)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { find.barTop = $0 }
                    .onDisappear { find.barTop = nil }
            }
        }
        // No tab bar on iPhone pages: more room, and its Search tab (for pages) isn't needed here.
        .toolbar(UIDevice.current.userInterfaceIdiom == .phone ? .hidden : .automatic, for: .tabBar)
        .onChange(of: find.query) { _, _ in updateFind(restart: true) }
        .onChange(of: find.matchCase) { _, _ in updateFind(restart: true) }
        .onChange(of: model?.document) { _, _ in
            if find.isShown { updateFind(restart: false) }
        }
        .onChange(of: model?.readerToggles) { _, _ in
            if find.isShown { updateFind(restart: false) }
        }
        .onChange(of: model?.active?.ref) { _, _ in
            // Tapping into the text ends find; the user continues typing there.
            if model?.active != nil, find.isShown { find.close() }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            // Count only real dismissals (keyboard leaves the screen). On device, iOS also sends "will hide" on a focus
            // change (frame stays) and when XCUITest types (hardware keyboard mode, only the keyboard toolbar stays).
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            if let window, window.convert(end, from: window.screen.coordinateSpace).minY >= window.bounds.maxY - 1 {
                debugKeyboardHides += 1
            }
        }
        .overlay(alignment: .topLeading) {
            Text(verbatim: "\(debugKeyboardHides)")
                .font(.system(size: 2))
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug-keyboard-hides")
        }
        #endif
    }

    // MARK: - Content

    private func baseDocument(_ page: Page) -> some View {
        BaseScreen(page: page, linkedRowId: selection.rowId) {
            VStack(alignment: .leading, spacing: 10) {
                if !breadcrumbs.isEmpty {
                    BreadcrumbsView(crumbs: breadcrumbs)
                }
                if page.isInTrash {
                    TrashBanner(page: page)
                }
                header(page)
            }
        }
    }

    private func document(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    if !breadcrumbs.isEmpty {
                        BreadcrumbsView(crumbs: breadcrumbs)
                    }
                    if page.isInTrash {
                        TrashBanner(page: page)
                    }
                    header(page)
                    Divider()
                    if let model {
                        if model.showsEmptyPlaceholder {
                            Text("This page is empty.")
                                .foregroundStyle(.secondary)
                        }
                        DocumentBody(model: model)
                        getStarted(model)
                    }
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // Space below the last block: tapping it puts the cursor at the end.
                Color.clear
                    .frame(height: trailingSpace)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        titleFocused = false
                        Task { await model?.activateTrailing() }
                    }
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if let model { PageEditor(model: model) }
            }
            .coordinateSpace(.named(DocumentModel.documentSpace))
        }
        .scrollPosition($position, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
        // Here, not with the page's other sheets: that chain is at the type checker's limit.
        .modifier(TemplatePickerSheet(isPresented: $showsTemplates, spaceId: page.spaceId) { template in
            try await fill(page, with: template)
        })
        .modifier(CentersAboveKeyboard(model: $model, find: find, position: $position, scrollHeight: $scrollHeight))
        .refreshable {
            if model?.isEditable != true {
                await load(force: true)
                model?.resume()
            }
        }
        .handlesLinks(handle)
        .onTapGesture {
            // Tap on empty space: unfocus the title; an active block editor stays active.
            titleFocused = false
        }
        .environment(\.pageFind, find)
        .background {
            // ⌘F on a hardware keyboard.
            Button("Find on Page") { openFind() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // Outside `CentersAboveKeyboard`: the banner is part of the scroll view's safe area there, so centering above the
        // keyboard keeps the cursor below it.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let error = model?.errorMessage { EditorMessageBanner(message: error) }
                if let warning = model?.unsentWarning { EditorMessageBanner(message: warning) }
            }
        }
    }

    /// Generous space while editing so even the last block can be centered above the keyboard
    /// (the keyboard doesn't shrink the scroll area, see `ignoresSafeArea(.keyboard)`).
    private var trailingSpace: CGFloat {
        model?.isEditable == true ? max(240, scrollHeight * 0.7) : 80
    }

    // MARK: - Find on page

    private func openFind() {
        guard !showsWebLayout, model != nil else { return }
        titleFocused = false
        model?.deactivate()
        find.show()
    }

    private func updateFind(restart: Bool) {
        guard let model else { return }
        find.update(document: model.document, baseURL: session.server?.url, toggles: model.readerToggles, restart: restart)
    }

    private func header(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    titleFocused = false
                    model?.deactivate()
                    showsEmojiPicker = true
                } label: {
                    if let icon = page.icon, !icon.isEmpty {
                        Text(icon).font(.system(size: 36))
                    } else {
                        Image(systemName: page.isBase == true ? "tablecells" : "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canEditMeta(page))
                .accessibilityLabel("Page icon")
                .accessibilityValue(page.icon ?? "")
                .accessibilityIdentifier("page-icon")
                .background {
                    // Opens the emoji keyboard; the typed emoji becomes the icon directly.
                    EmojiPickerField(isPresented: $showsEmojiPicker) { emoji in
                        Task { await setIcon(emoji) }
                    }
                    .frame(width: 1, height: 1)
                }
                if canEditMeta(page) {
                    TextField("Untitled", text: $titleEdit.text, axis: .vertical)
                        .font(.largeTitle.bold())
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("page-title")
                        .background {
                            AfterTransition {
                                guard focusesTitle else { return }
                                focusesTitle = false
                                titleFocused = true
                            }
                        }
                } else {
                    Text(titleEdit.unsent ?? page.displayTitle)
                        .font(.largeTitle.bold())
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if titleEdit.unsent != nil {
                Label("Not sent yet: the title goes to the server once it can be reached.", systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("page-title-unsent")
            }
            HStack(spacing: 8) {
                if let space = page.space {
                    NavigationLink(value: SpaceRoute(spaceId: space.id)) {
                        Chip(text: space.name ?? space.slug ?? "Space", symbol: "folder")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-space")
                }
                if let editor = page.lastUpdatedBy?.name ?? page.creator?.name {
                    Text(editor)
                }
                if let updatedAt = page.updatedAt {
                    Text("·")
                    Text("Updated \(updatedAt, format: .relative(presentation: .named))")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var pageMenu: some View {
        Menu {
            if let page = state.value {
                let isFavorite = favorites.isFavorite(pageId: page.id)
                Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star") {
                    Task { await favorites.togglePage(page.id) }
                }
                if page.isBase == true {
                    baseMenuItems(page)
                } else {
                    documentMenuItems(page)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("page-more")
        .disabled(state.value == nil)
        // On the menu, not the page: iOS shows the confirmation as a popover from the view it's attached to.
        .confirmationDialog("Move this page and its subpages to the trash?", isPresented: $confirmsTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await moveToTrash() } }
        }
    }

    /// Database (base) page: its document is empty and invisible in the web client, so offer nothing that writes to it.
    @ViewBuilder
    private func baseMenuItems(_ page: Page) -> some View {
        if page.canEdit {
            Divider()
            if page.isInTrash {
                Button("Restore from Trash", systemImage: "arrow.uturn.backward") { Task { await restore() } }
            } else {
                Button("Edit in Web Editor", systemImage: "pencil.and.scribble") { showsWebEditor = true }
                Button("Move to Trash", systemImage: "trash", role: .destructive) { confirmsTrash = true }
            }
        }
        if let url = webURL {
            Divider()
            Link(destination: url) { Label("Open in Browser", systemImage: "safari") }
            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    private func documentMenuItems(_ page: Page) -> some View {
        Button("Find on Page", systemImage: "text.magnifyingglass") { openFind() }
            .disabled(showsWebLayout)
        Button("Page History", systemImage: "clock.arrow.circlepath") { showsHistory = true }
        Button("Attachments", systemImage: "paperclip") { showsAttachments = true }
        Button("Presentation Mode", systemImage: "play.rectangle") { Task { await present(page) } }
        if page.canEdit {
            Divider()
            if page.isInTrash {
                Button("Restore from Trash", systemImage: "arrow.uturn.backward") { Task { await restore() } }
            } else {
                Button("New Subpage", systemImage: "doc.badge.plus") { Task { await createSubpage() } }
                if model?.isEditable == true {
                    Button("Arrange Blocks", systemImage: "arrow.up.arrow.down") { showsArrange = true }
                }
                Button("Append Note", systemImage: "text.append") { showsAppendNote = true }
                Button("Edit in Web Editor", systemImage: "pencil.and.scribble") { showsWebEditor = true }
                Button("Move to Trash", systemImage: "trash", role: .destructive) { confirmsTrash = true }
            }
        }
        Divider()
        Toggle("Web Layout", systemImage: "globe", isOn: $showsWebLayout)
        Button("Copy as Markdown", systemImage: "doc.on.doc") { Task { await copyMarkdown() } }
        if let url = webURL {
            Link(destination: url) { Label("Open in Browser", systemImage: "safari") }
            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Opens the presentation mode with the page as it is now, the text being typed included, as the web takes the
    /// live editor's content.
    private func present(_ page: Page) async {
        await model?.flush()
        model?.deactivate()
        let shownTitle: String? = canEditMeta(page) ? titleEdit.text : titleEdit.unsent ?? page.title
        presentation = Presentation(pageId: page.id, title: PageTitle.display(shownTitle),
                                    document: model.map { ContentParser.parse($0.document) } ?? ContentDocument(json: page.content))
    }

    /// As on the web: the server deletes a page's files since Docmost 0.97, only for space admins who may edit the page.
    private func canDeleteAttachments(of page: Page) -> Bool {
        session.ready?.hasDocmost097Features == true && page.canEdit && !page.isInTrash && !offline.isOffline
            && spaces.state.value?.first { $0.id == page.spaceId }?.role == .admin
    }

    /// Title and icon go through REST and need no engine.
    /// Offline the title and icon are read-only, like the text: a change couldn't be saved.
    private func canEditMeta(_ page: Page) -> Bool {
        page.canEdit && !page.isInTrash && !offline.isOffline
    }

    /// What the header and menu change, in the session the page loaded in.
    private var edits: PageEdits? {
        guard let page = state.value, let pageSession else { return nil }
        return PageEdits(page: page, owner: pageSession, session: session, changes: changes)
    }

    private var webURL: URL? {
        guard let server = session.server?.url, let slugId = state.value?.slugId else { return nil }
        return ContentLinkRouter.webPageURL(server: server, slugId: slugId)
    }

    // MARK: - Loading

    /// The saved copy first, then the server's page (`PageLoader`), in the session current now: the page's from then on.
    private func load(force: Bool) async {
        guard let ready = session.ready else { return }
        pageSession = ready
        let loader = PageLoader(pageId: selection.pageId, owner: ready, session: session)
        if state.value == nil || force {
            if state.value == nil {
                if let saved = await loader.saved() {
                    apply(page: saved.page, unsent: saved.unsent)
                    breadcrumbs = saved.breadcrumbs
                } else {
                    state = .loading
                }
            }
            do {
                let page = try await loader.fetch()
                apply(page: page)
                recentlyOpened.record(page)
                await loader.keep(page)
                #if DEBUG
                if let target = DebugLaunch.scrollBlockId {
                    position.scrollTo(id: target, anchor: .top)
                }
                #endif
            } catch let error as APIError where error.isGone {
                // Deleted for good or access removed: show that instead of the saved copy, and drop the copy.
                let stale = state.value
                model?.suspend()
                model = nil
                comments = nil
                find.close()
                state = .failed(error)
                recentlyOpened.remove(pageId: stale?.id ?? selection.pageId)
                await loader.forget(stale)
                return
            } catch is CancellationError {
                return
            } catch {
                if state.value == nil {
                    state = .failed(error)
                } else if offline.isOffline || ready.restoredOffline {
                    // The app's offline banner says it already.
                } else if case .network = error as? APIError {
                    toast = String(localized: "Offline – showing saved version")
                } else {
                    // Other server errors (e.g. 5xx): say so, as the web does; the saved copy stays.
                    toast = error.userMessage
                }
                return
            }
            if showsWebLayout { await loadWebHTML() }
        }
        if let crumbs = await loader.breadcrumbs(of: state.value) {
            breadcrumbs = crumbs
        }
        if let info = await loader.space(of: state.value) {
            space = info
            if let page = state.value { model?.canComment = canComment(on: page) }
        }
    }

    /// Applies page data; builds a new model unless the current one has an engine and the page stays editable.
    /// `unsent`: the document with changes the server doesn't have yet (`UnsentChanges`). Shown offline and until the
    /// engine's first sync (which sends them), also if the server can't be reached; not where they can't go.
    private func apply(page: Page, unsent: PMNode? = nil) {
        let isFirst = state.value == nil
        state = .loaded(page)
        titleEdit.show(page, typing: titleFocused)
        if isFirst, selection.focusTitle, canEditMeta(page) {
            focusesTitle = true
        }
        // A link to a comment: show it once the page is there.
        if isFirst, let commentId = selection.commentId, page.isBase != true {
            pendingCommentId = commentId
        }
        // Load comments right away for the button badge; database pages have none.
        if page.isBase != true, comments?.pageId != page.id {
            let store = PageComments(pageId: page.id, session: session)
            comments = store
            Task { await store.load() }
        }
        model?.canComment = canComment(on: page)
        // Turned into a database ("Get started with"): the text editor stops, the page shows the rows.
        if page.isBase == true, let model {
            model.suspend()
            self.model = nil
            return
        }
        if let model, model.engine != nil {
            if page.canEdit && !page.isInTrash { return }
            // Trashed or edit rights lost since the cached state: the collab server drops every edit, so rebuild read-only.
            model.suspend()
        }
        // A database page gets none: no document and no engine; its content is rows, not text.
        guard let pageSession, let created = PageLoader(pageId: selection.pageId, owner: pageSession, session: session)
            .model(for: page, unsent: unsent, isOffline: offline.isOffline, notices: notices, changes: changes) else { return }
        created.canComment = canComment(on: page)
        if created.dependencies.hasDocmost097Features, let previews = session.linkPreviews {
            // A pasted link is recognized only with the workspace's integrations known.
            Task { await previews.loadInstalled() }
        }
        model = created
        // A page that loaded after it left the screen (e.g. offline, back online under a pushed page) connects when it
        // shows again (`onAppear`), not hidden.
        if isOnScreen {
            registerSelectionCommands()
            created.resume()
        }
    }

    // MARK: - Comments

    private func canComment(on page: Page) -> Bool {
        Self.canComment(on: page, in: space, signedIn: session.ready != nil)
    }

    /// The server's rule (`validateCanComment`, also the web client's): with write permission, or as a reader when the
    /// space allows reader comments; never in the trash. The workspace role plays no part.
    static func canComment(on page: Page, in space: Space?, signedIn: Bool) -> Bool {
        signedIn && !page.isInTrash && (page.canEdit || space?.settings?["comments"]?["allowViewerComments"]?.boolValue == true)
    }

    private func openComments(focus commentId: String?) {
        commentsFocusId = commentId
        showsComments = true
    }

    private func dismissedComments() {
        commentsFocusId = nil
        // The page can only scroll once the sheet is gone.
        if let anchor = revealsAnchor {
            revealsAnchor = nil
            withAnimation { position.scrollTo(id: anchor, anchor: .center) }
        }
    }

    /// Shows a comment's passage by scrolling to the top-level block that contains its mark, once the comments are
    /// gone (`dismissedComments`).
    private func showInPage(_ comment: PageComment) {
        guard let model else { return }
        func contains(_ node: PMNode) -> Bool {
            node.marks?.contains { $0.type == "comment" && $0.string("commentId") == comment.id } == true || node.children.contains(where: contains)
        }
        guard let entry = model.topLevel.first(where: { contains($0.node) }) else { return }
        revealsAnchor = entry.ref.anchorId
    }

    /// Routes "Comment" in the editor's selection menu (UIKit, see `AppDelegate`) to this page.
    private func registerSelectionCommands() {
        guard let model else { return }
        EditorSelectionCommands.model = model
    }

    private func loadWebHTML() async {
        guard let edits else { return }
        do {
            webHTML = try await edits.content(as: "html")
        } catch is CancellationError {
        } catch {
            toast = error.userMessage
            showsWebLayout = false
        }
    }

    // MARK: - Actions

    /// Saves an edited title in the session the page loaded in (`PageTitleEdit.commit`).
    @discardableResult
    private func commitTitle() -> Task<Void, Never>? {
        guard let page = state.value, let pageSession else { return nil }
        return titleEdit.commit(page, in: pageSession, session: session, changes: changes,
                                sent: { await load(force: true) }, report: { toast = $0 })
    }

    /// "Get started with" (`GetStartedRow`), as on the web: databases need the `bases` license feature, templates the
    /// `templates` one; without them it offers nothing.
    private var offersDatabases: Bool { session.ready?.entitlements.has("bases") == true }
    private var offersTemplates: Bool { session.ready?.entitlements.has("templates") == true }

    /// An empty page's "Get started with" (`GetStartedRow`).
    @ViewBuilder
    private func getStarted(_ model: DocumentModel) -> some View {
        if model.isEditable, model.isBlank, offersDatabases || offersTemplates {
            GetStartedRow(offersDatabases: offersDatabases, offersTemplates: offersTemplates, start: startWith)
        }
    }

    private func startWith(_ choice: GetStartedRow.Choice) {
        switch choice {
        case .database: Task { await convertToDatabase(template: nil) }
        case .kanban: Task { await convertToDatabase(template: "kanban") }
        case .template: showsTemplates = true
        }
    }

    /// Turns the empty page into a database, as the web's "Get started with" does; the page then shows its rows.
    private func convertToDatabase(template: String?) async {
        guard let edits else { return }
        do {
            try await edits.convertToDatabase(template: template)
            await load(force: true)
        } catch {
            toast = error.userMessage
        }
    }

    /// Fills the empty page with a template as the web does: its content, and its title if the page has none.
    private func fill(_ page: Page, with template: PageTemplate) async throws {
        guard let model else { return }
        let full = template.content == nil ? try await session.send(Endpoints.Templates.info(templateId: template.id)) : template
        guard await model.fill(with: full.content.flatMap(PMNode.init(json:))?.children ?? []) else {
            throw TemplateError.pageNotEmpty
        }
        if titleEdit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let templateTitle = full.title, !templateTitle.isEmpty {
            titleEdit.text = templateTitle
            commitTitle()
        }
    }

    /// Shows the page's kept title, and sends it right away if the server answers again.
    private func showUnsentTitle() async {
        let sent = await titleEdit.showUnsent(of: state.value, typing: { titleFocused }, isOffline: { offline.isOffline },
                                              session: session, changes: changes) { toast = $0 }
        if sent { await load(force: true) }
    }

    private func setIcon(_ emoji: String?) async {
        guard let edits else { return }
        do {
            try await edits.setIcon(emoji)
            await load(force: true)
        } catch {
            toast = error.userMessage
        }
    }

    // MARK: - Media

    private var importTypes: [UTType] {
        switch model?.pendingMedia?.action {
        case .audio: [.audio]
        case .pdf: [.pdf]
        default: [.item]
        }
    }

    private func createSubpage() async {
        guard let edits else { return }
        do {
            if let next = try await edits.createSubpage() { navigation.open(next) }
        } catch {
            toast = error.userMessage
        }
    }

    private func copyMarkdown() async {
        guard let edits else { return }
        do {
            UIPasteboard.general.string = try await edits.content(as: "markdown")
            toast = String(localized: "Copied as Markdown")
        } catch {
            toast = error.userMessage
        }
    }

    private func moveToTrash() async {
        guard let edits else { return }
        do {
            // Queued like leaving the page: stopped beside it, an open still running would start the engine again.
            await model?.suspend().value
            model = nil
            try await edits.moveToTrash()
            toast = String(localized: "Moved to Trash")
            await load(force: true)
        } catch {
            toast = error.userMessage
            // Brings back the model stopped for the move, with the document `stop` kept; no request, so also offline.
            if model == nil, let current = state.value { apply(page: current) }
        }
    }

    private func restore() async {
        guard let edits else { return }
        do {
            try await edits.restore()
            toast = String(localized: "Page restored")
            await load(force: true)
        } catch {
            toast = error.userMessage
        }
    }

    // MARK: - Links

    /// A tapped link: pages, anchors, comments and atoms open here; links that leave the app go `outside`.
    private func handle(_ url: URL, outside: OpenURLAction) {
        let pageIds = [state.value?.slugId, state.value?.id, selection.pageId]
        switch PageLinkAction.action(for: url, serverURL: session.server?.url, pageIds: pageIds) {
        case .showComment(let commentId):
            openComments(focus: commentId)
        case .editAtom(let block, let type, let index):
            model?.editAtom(blockIdentity: block, type: type, index: index)
        case .scroll(let anchor):
            scroll(to: anchor)
        case .anchor(let anchor):
            if model?.focusFootnote(dataId: anchor) == true { return }
            scroll(to: anchor)
        case .open(let selection):
            navigation.open(selection)
        case .outside(let external):
            outside(external)
        case .none:
            break
        }
    }

    private func scroll(to anchor: String) {
        guard let model, let id = Self.scrollTarget(for: anchor, in: model.document) else { return }
        withAnimation { position.scrollTo(id: id, anchor: .top) }
    }

    /// View id for a link to `#anchor` (a block's `id` or `data-id`, as on the web). Only footnotes and top-level
    /// blocks have view ids, so a nested target (heading in columns, toggle, table) scrolls to its top-level block.
    static func scrollTarget(for anchor: String, in document: PMNode) -> String? {
        let parsed = ContentParser.parse(document)
        // Footnotes first: the reference in the text has the same `data-id` as its footnote.
        if let footnote = parsed.anchors[anchor], parsed.footnotes.contains(where: { $0.id == footnote }) { return footnote }
        func contains(_ node: PMNode) -> Bool {
            node.string("id") == anchor || node.string("data-id") == anchor || node.children.contains(where: contains)
        }
        return NodeEntry.entries(document.children, parentPath: []).first { contains($0.node) }?.ref.anchorId
    }
}
