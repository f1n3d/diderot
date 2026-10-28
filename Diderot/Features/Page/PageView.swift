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
    /// A title the server didn't get yet (`UnsentTitle`): shown with a note until it goes out.
    @State private var unsentTitle: String?
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    /// Title whose save is running: a focus loss right after leaving the page would send it a second time.
    @State private var savingTitle: String?
    @State private var showsWebLayout = DebugLaunch.webLayout
    @State private var webHTML: String?
    @State private var showsComments = DebugLaunch.route == "comments"
    @State private var comments: PageComments?
    /// Comment the sheet jumps to on open (tap on a highlighted passage).
    @State private var commentsFocusId: String?
    /// A web page in the in-app browser (an integration mention's link).
    @State private var browsing: URL?
    /// The page's space; its settings say whether readers may comment.
    @State private var space: Space?
    @State private var showsHistory = DebugLaunch.route == "history"
    @State private var showsEmojiPicker = false
    @State private var showsAppendNote = false
    @State private var showsWebEditor = DebugLaunch.route == "webeditor"
    @State private var showsArrange = false
    /// The page for the presentation mode, as it was when it opened (as on the web).
    @State private var presentation: Presentation?
    @State private var showsAttachments = false
    @State private var confirmsTrash = false
    @State private var showsPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    /// Running uploads (a second media command may start one during the first).
    @State private var uploads = 0
    /// Height of the page view below the navigation bar (ignoring the keyboard); sizes the trailing space.
    @State private var scrollHeight: CGFloat = 0
    @State private var centering = CenteringState()
    @State private var keyboard = KeyboardObserver()
    @State private var find = PageFind()
    /// The templates for an empty page ("Get started with").
    @State private var showsTemplates = false
    #if DEBUG
    /// Test hook: counts full keyboard dismissals so UI tests can check the keyboard stays up across block switches.
    @State private var debugKeyboardHides = 0
    @State private var appliedDebugHooks = false
    #endif

    /// Geometry and state for centering above the keyboard; a class so scrolling and keyboard animations don't
    /// rebuild the view every frame.
    ///
    /// Coordinates: `frame` is the page view's area inside the insets (below the navigation bar) in window coordinates;
    /// the scroll area extends `safeTop` above it. `offset` (= `contentOffset.y`) is the content y at the scroll area's
    /// top edge; `ScrollPosition.scrollTo(y:)` counts from the content start inside the insets: `offset + insetTop`.
    private final class CenteringState {
        var frame: CGRect = .zero
        var safeTop: CGFloat = 0
        var offset: CGFloat = 0
        var insetTop: CGFloat = 0
        /// Top edge of the docked keyboard in window coordinates; `nil` without one.
        var keyboardTop: CGFloat?
        /// Top edge of the find bar in window coordinates; `nil` while hidden.
        var findBarTop: CGFloat?
        var userScrolling = false
        /// Until then, the just-activated editor is re-centered when it changes; afterwards it's only kept visible.
        var centerUntil = Date.distantPast
        /// Target of the running scroll animation.
        var target: CGFloat?
        var targetUntil = Date.distantPast
        var task: Task<Void, Never>?
        var hideTask: Task<Void, Never>?

        var isCentering: Bool { centerUntil > .now }
        var current: CGFloat { offset + insetTop }
        var pendingTarget: CGFloat? { targetUntil > .now ? target : nil }

        /// Visible range between navigation bar and keyboard in window coordinates.
        var visibleRange: ClosedRange<CGFloat>? {
            guard frame.height > 0 else { return nil }
            let bottom = min(frame.maxY, keyboardTop ?? .infinity)
            guard bottom - frame.minY > 80 else { return nil }
            return frame.minY...bottom
        }

        /// Window y of a content point at the current scroll position.
        func windowY(of contentY: CGFloat) -> CGFloat {
            contentY - offset + (frame.minY - safeTop)
        }

        /// Scroll target that puts content point `contentY` at window y `windowY`; independent of the current scroll
        /// position, so it stays correct during a running animation.
        func scrollTarget(placing contentY: CGFloat, atWindowY windowY: CGFloat) -> CGFloat {
            contentY - windowY + (frame.minY - safeTop) + insetTop
        }
    }

    /// Content with navigation bar, toolbars and floating buttons.
    private var chrome: some View {
        AsyncContentView(state: state, retry: { await load(force: true) }) { page in
            if page.isBase == true {
                baseDocument(page)
            } else if showsWebLayout, let webHTML, let serverURL = session.server?.url {
                WebLayoutView(html: webHTML, title: page.displayTitle, serverURL: serverURL, token: session.ready?.token)
                    .handlesLinks(handle)
            } else {
                document(page)
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
                    StatusPill(status: model.status, readOnlyReason: model.readOnlyReason, compact: horizontalSizeClass == .compact)
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
            if uploads > 0 {
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
        .sheet(item: $browsing) { url in
            SafariView(url: url).ignoresSafeArea()
        }
        .confirmationDialog("Link", isPresented: Binding { model?.mentionActions != nil } set: { if !$0 { model?.mentionActions = nil } },
                            titleVisibility: .hidden, presenting: model?.mentionActions) { target in
            Button("Open Link") { browsing = URL(string: target.url) }
            if model?.canShowAsCard(target) == true {
                Button("Show as Card") { Task { await model?.showMention(target, as: .card) } }
            }
            Button("Show as URL") { Task { await model?.showMention(target, as: .link) } }
            Button("Remove", role: .destructive) {
                Task { await model?.replaceAtom(ofType: "integrationMention", in: target.ref, index: target.index, with: nil) }
            }
        }
        .sheet(isPresented: $showsComments, onDismiss: { commentsFocusId = nil }) {
            if let page = state.value, let comments {
                CommentsView(page: page, comments: comments, canComment: canComment(on: page),
                             isSpaceAdmin: spaces.state.value?.first { $0.id == page.spaceId }?.role == .admin,
                             focusId: commentsFocusId) { comment in
                    showInPage(comment)
                }
                .handlesLinks { url, outside in
                    // Pages and anchors open on the page, so the comments make way; web links open over them.
                    switch ContentLinkRouter.destination(for: url, serverURL: session.server?.url) {
                    case .page, .databaseEntry, .anchor, .comment:
                        showsComments = false
                        handle(url, outside: outside)
                    case .user: break
                    case .external(let external): outside(external)
                    }
                }
                .opensExternalLinks()
            }
        }
        .sheet(isPresented: Binding(get: { model?.editsComment ?? false }, set: { model?.editsComment = $0 })) {
            if let model, let comments { InlineCommentSheet(model: model, comments: comments) }
        }
        .sheet(isPresented: $showsHistory) {
            if let page = state.value { HistoryView(page: page) }
        }
        .sheet(isPresented: $showsAppendNote) {
            if let page = state.value {
                AppendNoteSheet(page: page) { Task { await load(force: true) } }
            }
        }
        .sheet(isPresented: $showsArrange) {
            if let model { ArrangeSheet(model: model) }
        }
        .sheet(isPresented: $showsAttachments) {
            if let page = state.value { PageAttachmentsView(page: page, canDelete: canDeleteAttachments(of: page)) }
        }
        .sheet(isPresented: Binding(get: { model?.editsLink ?? false }, set: { model?.editsLink = $0 })) {
            if let model { LinkSheet(model: model) }
        }
        .sheet(item: Binding(get: { model?.editorSheet }, set: { model?.editorSheet = $0 }), onDismiss: { model?.editorSheetDismissed() }) { sheet in
            if let model { EditorSheetView(model: model, sheet: sheet) }
        }
        .fullScreenCover(isPresented: $showsWebEditor) {
            if let page = state.value, let serverURL = session.server?.url, let token = session.ready?.token {
                WebEditorView(page: page, serverURL: serverURL, token: token) {
                    Task { await load(force: true) }
                    changes.pageChanged(in: page.spaceId)
                }
                .opensExternalLinks()
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: nil,
                      matching: model?.pendingMedia?.action == .videos ? .videos : .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty, let model else { return }
            let target = model.takeMediaTarget()
            photoItems = []
            startUpload(in: model)
            Task { await uploadPhotos(items, to: target, in: model) }
        }
        .fullScreenCover(item: $presentation) { presentation in
            PresentationView(pageId: presentation.pageId, title: presentation.title, document: presentation.document) { url in
                handle(url, outside: OpenURLAction { _ in .discarded })
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraPicker { data in
                guard let model else { return }
                let target = model.takeMediaTarget()
                startUpload(in: model)
                Task { await upload([UploadFile.camera(data)], to: target, in: model) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard let model else { return }
                let target = model.takeMediaTarget()
                startUpload(in: model)
                Task { await uploadFiles(at: urls, to: target, in: model) }
            case .failure(let error):
                toast = error.localizedDescription
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
        .onChange(of: model?.engine?.document) { _, _ in
            model?.syncFromEngine()
            #if DEBUG
            if let model, model.isLive, !appliedDebugHooks {
                appliedDebugHooks = true
                Task { await model.applyDebugHooks() }
            }
            #endif
        }
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
        .onChange(of: title) { _, value in
            if value.contains("\n") {
                title = value.replacingOccurrences(of: "\n", with: " ")
                titleFocused = false
            }
        }
        .onAppear {
            isOnScreen = true
            keyboard.start { top, duration in keyboardChanged(top: top, duration: duration) }
            registerSelectionCommands()
            model?.resume()
        }
        // Back in the app: an editor that failed to open, or whose web process ended while opening, tries again.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isOnScreen { model?.resume() }
            // iOS may end the app in the background, and an app swiped away in the app switcher never gets there: keep
            // unsent changes as leaving the page would.
            if phase != .active, let model {
                let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                Task {
                    await model.saveUnsentChanges()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
        }
        .onDisappear {
            isOnScreen = false
            // The page can leave while its title still has focus (no `onChange` then): save the edit, like the web.
            if titleFocused { commitTitle() }
            keyboard.stop()
            if let model, EditorSelectionCommands.model === model { EditorSelectionCommands.model = nil }
            // The camera's full-screen cover is the page's own picker: the page stays live under it, for the photo.
            if showsCamera { model?.deactivate() } else { model?.leave() }
        }
        // No automatic keyboard avoidance (it jumps before centering runs); `keyboardChanged` handles the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Find bar outside of that: it sits above the keyboard and the document gets bottom space for it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if find.isShown {
                PageFindBar(find: find)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { centering.findBarTop = $0 }
                    .onDisappear { centering.findBarTop = nil }
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
        .onChange(of: find.revealRequest) { _, _ in revealFindMatch() }
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
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
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
        .onGeometryChange(for: ViewGeometry.self) { geometry in
            ViewGeometry(frame: geometry.frame(in: .global), safeTop: geometry.safeAreaInsets.top, safeBottom: geometry.safeAreaInsets.bottom)
        } action: { geometry in
            centering.frame = geometry.frame
            centering.safeTop = geometry.safeTop
            // Down to the bottom edge.
            let height = geometry.frame.height + geometry.safeBottom
            if abs(height - scrollHeight) > 1 { scrollHeight = height }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(offset: geometry.contentOffset.y, insetTop: geometry.contentInsets.top)
        } action: { _, metrics in
            centering.offset = metrics.offset
            centering.insetTop = metrics.insetTop
        }
        .onScrollPhaseChange { _, phase in
            // Never scroll against the user (this also cancels pending centering).
            centering.userScrolling = phase == .interacting || phase == .decelerating
            if centering.userScrolling { centering.task?.cancel() }
            if phase != .animating { centering.target = nil }
        }
        .onChange(of: model?.active?.ref) { _, _ in
            activeBlockChanged()
        }
        .onChange(of: model?.activeBlockFrame) { _, _ in
            activeFrameChanged()
        }
        .onChange(of: model?.cursorRequest == nil) { _, placed in
            if placed { cursorPlaced() }
        }
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
    }

    private nonisolated struct ViewGeometry: Equatable, Sendable {
        let frame: CGRect
        let safeTop: CGFloat
        let safeBottom: CGFloat
    }

    private nonisolated struct ScrollMetrics: Equatable, Sendable {
        let offset: CGFloat
        let insetTop: CGFloat
    }

    /// Generous space while editing so even the last block can be centered above the keyboard
    /// (the keyboard doesn't shrink the scroll area, see `ignoresSafeArea(.keyboard)`).
    private var trailingSpace: CGFloat {
        model?.isEditable == true ? max(240, scrollHeight * 0.7) : 80
    }

    // MARK: - Centering above the keyboard

    /// A block became active: center it above the keyboard in one motion as the keyboard slides in (its notification
    /// triggers that in `keyboardChanged`). With the keyboard already up, the placed caret does it (`cursorPlaced`):
    /// started right away, the motion ran while the editor was built, dropped frames, and restarted when the editor
    /// settled. After Return or Backspace the page keeps its place instead, as in other editors.
    private func activeBlockChanged() {
        centering.task?.cancel()
        guard let model, model.active != nil else {
            centering.centerUntil = .distantPast
            return
        }
        scrollToUnbuiltActiveBlock()
        // `cursorPlaced` only keeps the new caret visible.
        guard !model.activatedByTyping else {
            centering.centerUntil = .distantPast
            return
        }
        // Right after the tap the editor still changes (height, table bar); keep re-centering it for that long.
        centering.centerUntil = .now + 0.8
        guard centering.keyboardTop == nil else { return }
        centering.task = Task { @MainActor in
            // Without a keyboard this is only the fallback in case none appears (hardware keyboard without toolbar).
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            center(duration: 0.3)
        }
    }

    private func scrollToUnbuiltActiveBlock() {
        // A block outside the visible area (e.g. added at the page end via the floating "+") isn't built by the lazy
        // list yet, and without an editor there's no focus, so scroll there first, unanimated: during an animated move
        // the list sometimes rebuilds the editor. Near the page end, scrolling to the ID doesn't help while the block
        // isn't built, so jump to the bottom and step back up until it's measured.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            // Never against the user's own scrolling (here and in the steps below).
            guard let model, let active = model.active, model.activeBlockFrame == .zero, !centering.userScrolling,
                  let top = active.ref.path.first, model.topLevel.indices.contains(top)
            else { return }
            centering.centerUntil = .now + 1.5
            guard top >= model.topLevel.count - 6 else {
                position.scrollTo(id: model.topLevel[top].ref.anchorId, anchor: .center)
                return
            }
            position.scrollTo(edge: .bottom)
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(150))
                guard model.active?.ref == active.ref, model.activeBlockFrame == .zero, !centering.userScrolling else { return }
                position.scrollTo(y: max(0, centering.current - 400))
            }
        }
    }

    /// The keyboard moved; hiding it never scrolls.
    private func keyboardChanged(top: CGFloat?, duration: Double) {
        centering.hideTask?.cancel()
        guard let top else {
            // When switching between two blocks iOS often reports "hidden" and immediately "shown" again, so while a
            // block is active the keyboard only counts as gone after a delay.
            if model?.active == nil {
                centering.keyboardTop = nil
            } else {
                centering.hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    centering.keyboardTop = nil
                }
            }
            return
        }
        let changed = centering.keyboardTop.map { abs($0 - top) > 1 } ?? true
        centering.keyboardTop = top
        guard changed, model?.active != nil else { return }
        if centering.isCentering {
            centering.task?.cancel()
            center(duration: duration)
        } else {
            reveal(duration: duration)
        }
    }

    /// The active editor changed size or position (line wrap, slash/mention menu, table bar).
    private func activeFrameChanged() {
        guard let model, model.active != nil, model.activeBlockFrame.height > 0 else { return }
        if centering.isCentering {
            // While the keyboard is still coming, its notification does the centering; with it up, the placed caret
            // starts it (`cursorPlaced`).
            if centering.keyboardTop != nil, model.cursorRequest == nil { center(duration: 0.35) }
        } else if !model.isSwitchingByTyping {
            reveal(duration: 0.2)
        }
    }

    /// The new editor has focus and its caret: the work of the switch is done, so the centering runs without dropping
    /// frames (started with the editor's first frame, it stuttered for about 150 ms). Without centering (Return,
    /// Backspace) the caret only stays visible.
    private func cursorPlaced() {
        if !centering.isCentering {
            reveal(duration: 0.2)
        } else if centering.keyboardTop != nil {
            center(duration: 0.35)
        }
    }

    /// Centers the active editor in the visible range. From 80% of the range's height, its end (where the cursor sits
    /// after the tap) is aligned to the bottom instead.
    private func center(duration: Double) {
        guard let model, model.active != nil, !centering.userScrolling, let visible = centering.visibleRange else { return }
        let editor = model.activeBlockFrame
        guard editor.height > 0 else { return }
        let fits = editor.height < (visible.upperBound - visible.lowerBound) * 0.8
        let target = fits
            ? centering.scrollTarget(placing: editor.midY, atWindowY: (visible.lowerBound + visible.upperBound) / 2)
            : centering.scrollTarget(placing: editor.maxY, atWindowY: visible.upperBound - 8)
        scroll(to: target, duration: duration)
    }

    /// Keeps what matters visible while typing, moving minimally: with a slash or mention menu open, the block and its
    /// menu (the block's first line wins), else the cursor line (the editor's last line when the cursor is at the end).
    private func reveal(duration: Double) {
        guard let model, model.active != nil, !centering.userScrolling, let visible = centering.visibleRange else { return }
        let frame = model.activeBlockFrame
        guard frame.height > 0 else { return }
        // During a running scroll animation, compute from its target (window positions there, not now).
        let base = centering.pendingTarget ?? centering.current
        let shift = base - centering.current
        let rect: CGRect
        if model.slashQuery != nil || model.mentionQuery != nil {
            rect = CGRect(x: frame.minX, y: centering.windowY(of: frame.minY) - shift, width: frame.width, height: frame.height)
        } else if case .point(let point)? = model.cursorRequest {
            // Tapped: the caret goes to that line shortly (`ActiveTextEditor`), not to the end it starts at.
            rect = CGRect(x: frame.minX, y: centering.windowY(of: frame.minY + point.y) - 18 - shift, width: frame.width, height: 36)
        } else if model.cursorRequest != nil {
            // Not placed yet: the selection still belongs to the previous block, and `cursorPlaced` comes back here.
            return
        } else if model.isCursorAtEnd {
            let lineTop = max(frame.minY, frame.maxY - 36)
            rect = CGRect(x: frame.minX, y: centering.windowY(of: lineTop) - shift, width: frame.width, height: frame.maxY - lineTop)
        } else if let caret = FirstResponder.caretRectInWindow {
            rect = caret.offsetBy(dx: 0, dy: -shift).insetBy(dx: 0, dy: -6)
        } else {
            return
        }
        let top = visible.lowerBound + 8
        // A line of air above the keyboard's bar shows that the page goes on.
        let bottom = visible.upperBound - 38
        var delta: CGFloat = 0
        if rect.maxY > bottom { delta = rect.maxY - bottom }
        if rect.minY - delta < top { delta = rect.minY - top }
        guard abs(delta) > 1 else { return }
        scroll(to: base + delta, duration: duration)
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

    /// Goes to the current match: if its block is known (it reports its frame once it holds the match), center it
    /// above the find bar; otherwise first scroll to the enclosing top-level block, which then loads it.
    private func revealFindMatch() {
        guard let match = find.currentMatch else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard find.currentMatch == match else { return }
            if let current = find.currentFrame, current.ref == match.ref {
                centerFindMatch(current.frame)
                return
            }
            position.scrollTo(id: match.topLevel.anchorId, anchor: .center)
            try? await Task.sleep(for: .milliseconds(150))
            guard find.currentMatch == match, let current = find.currentFrame, current.ref == match.ref else { return }
            centerFindMatch(current.frame)
        }
    }

    private func centerFindMatch(_ frame: CGRect) {
        let top = centering.frame.minY
        let bottom = min(centering.findBarTop ?? .infinity, centering.keyboardTop ?? .infinity, centering.frame.maxY)
        guard bottom - top > 60 else { return }
        scroll(to: centering.scrollTarget(placing: frame.midY, atWindowY: (top + bottom) / 2), duration: 0.3)
    }

    /// Animates to `target` (`ScrollPosition.scrollTo(y:)` units) without restarting a running animation to it.
    private func scroll(to target: CGFloat, duration: Double) {
        let target = max(0, target)
        guard abs(target - (centering.pendingTarget ?? centering.current)) > 1 else { return }
        centering.target = target
        centering.targetUntil = .now + duration + 0.2
        // A spring: a new target mid-motion (the editor settling, the keyboard) keeps the current speed.
        withAnimation(.smooth(duration: duration)) {
            position.scrollTo(y: target)
        }
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
                    TextField("Untitled", text: $title, axis: .vertical)
                        .font(.largeTitle.bold())
                        .focused($titleFocused)
                        .submitLabel(.done)
                        .accessibilityIdentifier("page-title")
                } else {
                    Text(unsentTitle ?? page.displayTitle)
                        .font(.largeTitle.bold())
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            if unsentTitle != nil {
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
        let shownTitle: String? = canEditMeta(page) ? title : unsentTitle ?? page.title
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

    private var webURL: URL? {
        guard let server = session.server?.url, let slugId = state.value?.slugId else { return nil }
        return ContentLinkRouter.webPageURL(server: server, slugId: slugId)
    }

    // MARK: - Loading

    private func load(force: Bool) async {
        guard let ready = session.ready else { return }
        let client = ready.client
        let cache = ready.cache
        if state.value == nil || force {
            if state.value == nil {
                if let cached = await cache.read(Page.self, key: CacheKey.page(selection.pageId)) {
                    let unsent = await ready.unsentChanges.read(PMNode.self, key: CacheKey.unsentDocument(cached.id))
                    apply(page: cached, unsent: unsent)
                    breadcrumbs = await cache.read([Breadcrumb].self, key: CacheKey.breadcrumbs(cached.id)) ?? []
                } else {
                    state = .loading
                }
            }
            do {
                let page = try await session.perform { try await client.send(Endpoints.Pages.info(pageId: selection.pageId)) }
                apply(page: page)
                recentlyOpened.record(page)
                await cache.write(page, key: CacheKey.page(page.id))
                if let slugId = page.slugId, slugId != page.id {
                    await cache.write(page, key: CacheKey.page(slugId))
                }
                if let target = DebugLaunch.scrollBlockId {
                    position.scrollTo(id: target, anchor: .top)
                }
            } catch let error as APIError where error.isGone {
                // Deleted for good or access removed: show that instead of the saved copy, and drop the copy.
                let stale = state.value
                model?.suspend()
                model = nil
                comments = nil
                find.close()
                state = .failed(Self.gone(error))
                recentlyOpened.remove(pageId: stale?.id ?? selection.pageId)
                for key in [stale?.id, stale?.slugId].compactMap({ $0 }) {
                    await cache.remove(key: CacheKey.page(key))
                }
                if let stale { await Self.removeSavedData(of: stale, from: cache) }
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
        if let crumbs = try? await session.perform({ try await client.send(Endpoints.Pages.breadcrumbs(pageId: selection.pageId)) }) {
            breadcrumbs = crumbs
            if let pageId = state.value?.id {
                await cache.write(crumbs, key: CacheKey.breadcrumbs(pageId))
            }
        }
        if let spaceId = state.value?.spaceId, let info = try? await session.perform({ try await client.send(Endpoints.Spaces.info(spaceId: spaceId)) }) {
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
        if !titleFocused { title = unsentTitle ?? page.title ?? "" }
        if isFirst, selection.focusTitle, canEditMeta(page) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                titleFocused = true
            }
        }
        // A link to a comment: show it once the page is there.
        if isFirst, let commentId = selection.commentId, page.isBase != true {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                openComments(focus: commentId)
            }
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
        // Database page: no document and no engine; its content is rows, not text.
        if page.isBase == true { return }
        let reason: DocumentModel.ReadOnlyReason? = page.isInTrash ? .trash : !page.canEdit ? .noPermission : offline.isOffline ? .offline
            : session.ready?.newerServerVersion.map { .newerServer($0) }
        let live = LiveDocuments.document(for: page.id, newerThan: page.updatedAt, serverClockOffset: session.client?.serverClockOffset ?? 0)
        let engine = reason == nil ? WebDocumentEngine(session: session) : nil
        let created = DocumentModel(page: page, initialDocument: live ?? (reason == nil || reason == .offline ? unsent : nil), engine: engine, readOnlyReason: reason)
        created.currentUserId = session.ready?.currentUser.user.id
        created.canComment = canComment(on: page)
        created.canCreateBases = session.ready?.entitlements.has("bases") == true
        created.hasDocmost097Features = session.ready?.hasDocmost097Features == true
        created.linkPreviews = session.linkPreviews
        if created.hasDocmost097Features, let previews = session.linkPreviews {
            // A pasted link is recognized only with the workspace's integrations known.
            Task { await previews.loadInstalled() }
        }
        created.serverURL = session.server?.url
        created.lookUpPage = { [session] slugId in try? await session.send(Endpoints.Pages.info(pageId: slugId)) }
        let changes = changes
        created.createBase = { template in
            let base = try await session.send(Endpoints.Bases.create(parentPageId: page.id, template: template))
            changes.pageChanged(in: page.spaceId)
            return base.id
        }
        let session = session
        let spaceId = page.spaceId
        created.suggest = { query in
            try await session.send(Endpoints.Search.suggest(query: query, users: true, pages: true, spaceId: spaceId, limit: 8))
        }
        model = created
        registerSelectionCommands()
        created.resume()
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

    /// Shows a comment's passage by scrolling to the top-level block that contains its mark.
    private func showInPage(_ comment: PageComment) {
        guard let model else { return }
        func contains(_ node: PMNode) -> Bool {
            node.marks?.contains { $0.type == "comment" && $0.string("commentId") == comment.id } == true || node.children.contains(where: contains)
        }
        guard let entry = model.topLevel.first(where: { contains($0.node) }) else { return }
        Task { @MainActor in
            // The page can only scroll once the sheet is gone.
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation { position.scrollTo(id: entry.ref.anchorId, anchor: .center) }
        }
    }

    /// Routes "Comment" in the editor's selection menu (UIKit, see `AppDelegate`) to this page.
    private func registerSelectionCommands() {
        guard let model else { return }
        EditorSelectionCommands.model = model
    }

    /// The error for a page gone for good or no longer shared, in the app's language (the server's is English).
    private static func gone(_ error: APIError) -> APIError {
        if case .forbidden = error { return .forbidden(message: String(localized: "You no longer have access to this page.")) }
        return .notFound(message: String(localized: "This page doesn't exist anymore."))
    }

    /// What else the device keeps of a page gone for good: its breadcrumbs, its level in the page tree and, for a
    /// database, its views' rows.
    private static func removeSavedData(of page: Page, from cache: DiskCache) async {
        await cache.remove(key: CacheKey.breadcrumbs(page.id))
        if let spaceId = page.spaceId {
            await cache.remove(key: CacheKey.tree(spaceId: spaceId, parentPageId: page.id))
        }
        if let base = await cache.read(Base.self, key: CacheKey.base(page.id)) {
            for view in base.views { await cache.remove(key: CacheKey.baseView(page.id, viewId: view.id)) }
            await cache.remove(key: CacheKey.base(page.id))
        }
    }

    private func loadWebHTML() async {
        guard session.client != nil else { return }
        do {
            let page = try await session.send(Endpoints.Pages.info(pageId: selection.pageId, format: "html"))
            webHTML = page.content?.stringValue ?? ""
        } catch is CancellationError {
        } catch {
            toast = error.userMessage
            showsWebLayout = false
        }
    }

    // MARK: - Actions

    /// Saves an edited title; reads the view's values before the task starts, so it also works from `onDisappear`. One
    /// the server doesn't get (offline, unreachable) stays on the device and goes out later (`AppSession.sendUnsentTitles`).
    private func commitTitle() {
        guard let page = state.value, session.client != nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (page.title ?? ""), trimmed != savingTitle else { return }
        savingTitle = trimmed
        Task {
            // First: an older kept title going out meanwhile would overwrite this one.
            await session.forgetUnsentTitle(pageId: page.id)
            do {
                // The response lacks permissions and space info, so reload instead of replacing the page.
                _ = try await session.send(Endpoints.Pages.update(pageId: page.id, title: trimmed))
                unsentTitle = nil
                changes.pageChanged(in: page.spaceId)
                await load(force: true)
            } catch where UnsentTitle.isFinal(error) {
                toast = error.userMessage
            } catch {
                await session.keepUnsentTitle(trimmed, pageId: page.id, spaceId: page.spaceId)
                unsentTitle = trimmed
                toast = String(localized: "The title goes to the server once it can be reached.")
            }
            savingTitle = nil
        }
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
        guard let page = state.value else { return }
        do {
            _ = try await session.send(Endpoints.Bases.convert(pageId: page.id, template: template))
            changes.pageChanged(in: page.spaceId)
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
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let templateTitle = full.title, !templateTitle.isEmpty {
            title = templateTitle
            commitTitle()
        }
    }

    /// Shows the page's kept title, and sends it right away if the server answers again.
    private func showUnsentTitle() async {
        guard let page = state.value, let kept = await session.unsentTitle(pageId: page.id) else {
            unsentTitle = nil
            return
        }
        unsentTitle = kept
        if !titleFocused { title = kept }
        guard !offline.isOffline else { return }
        for spaceId in await session.sendUnsentTitles() { changes.pageChanged(in: spaceId) }
        guard await session.unsentTitle(pageId: page.id) == nil else { return }
        unsentTitle = nil
        await load(force: true)
    }

    private func setIcon(_ emoji: String?) async {
        guard let page = state.value, session.client != nil else { return }
        do {
            _ = try await session.send(Endpoints.Pages.update(pageId: page.id, icon: emoji ?? ""))
            changes.pageChanged(in: page.spaceId)
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

    private func uploadPhotos(_ items: [PhotosPickerItem], to target: MediaTarget, in model: DocumentModel) async {
        var files: [UploadFile] = []
        for item in items {
            do {
                if let file = try await UploadFile.photo(item) { files.append(file) }
            } catch {
                toast = error.localizedDescription
            }
        }
        await upload(files, to: target, in: model)
    }

    private func uploadFiles(at urls: [URL], to target: MediaTarget, in model: DocumentModel) async {
        var files: [UploadFile] = []
        for url in urls {
            do {
                files.append(try await UploadFile.file(at: url))
            } catch {
                toast = error.localizedDescription
            }
        }
        await upload(files, to: target, in: model)
    }

    /// Counts an upload as soon as its picker closes; it always ends in `upload`. The model keeps its page's engine open
    /// for it, also when the page leaves meanwhile (`DocumentModel.leave`).
    private func startUpload(in model: DocumentModel) {
        uploads += 1
        model.uploadStarted()
    }

    /// Uploads the files one by one and inserts them together at the target, in the page they were picked for.
    private func upload(_ files: [UploadFile], to target: MediaTarget, in model: DocumentModel) async {
        defer {
            uploads -= 1
            model.uploadEnded()
        }
        guard let client = session.client, !files.isEmpty else { return }
        let pageId = model.page.id
        var attachments: [Attachment] = []
        for file in files {
            do {
                let attachment = try await session.perform {
                    try await client.uploadAttachment(pageId: pageId, fileName: file.fileName, mimeType: file.mimeType, data: file.data)
                }
                attachments.append(attachment)
            } catch {
                toast = error.userMessage
            }
        }
        await model.insertUploads(attachments, to: target)
    }

    private func createSubpage() async {
        guard session.client != nil, let page = state.value, let spaceId = page.spaceId else { return }
        do {
            let created = try await session.send(Endpoints.Pages.create(spaceId: spaceId, parentPageId: page.id, title: nil))
            changes.pageChanged(in: spaceId)
            var next = PageSelection(page: created)
            next.focusTitle = true
            navigation.open(next)
        } catch {
            toast = error.userMessage
        }
    }

    private func copyMarkdown() async {
        guard session.client != nil else { return }
        do {
            let page = try await session.send(Endpoints.Pages.info(pageId: selection.pageId, format: "markdown"))
            UIPasteboard.general.string = page.content?.stringValue ?? ""
            toast = String(localized: "Copied as Markdown")
        } catch {
            toast = error.userMessage
        }
    }

    private func moveToTrash() async {
        guard session.client != nil, let page = state.value else { return }
        do {
            // Queued like leaving the page: stopped beside it, an open still running would start the engine again.
            await model?.suspend().value
            model = nil
            _ = try await session.send(Endpoints.Pages.delete(pageId: page.id))
            changes.pageChanged(in: page.spaceId)
            toast = String(localized: "Moved to Trash")
            await load(force: true)
        } catch {
            toast = error.userMessage
            // Brings back the model stopped for the move, with the document `stop` kept; no request, so also offline.
            if model == nil, let current = state.value { apply(page: current) }
        }
    }

    private func restore() async {
        guard session.client != nil, let page = state.value else { return }
        do {
            _ = try await session.send(Endpoints.Pages.restore(pageId: page.id))
            changes.pageChanged(in: page.spaceId)
            toast = String(localized: "Page restored")
            await load(force: true)
        } catch {
            toast = error.userMessage
        }
    }

    // MARK: - Links

    /// A tapped link: pages, anchors, comments and atoms open here; links that leave the app go `outside`.
    private func handle(_ url: URL, outside: OpenURLAction) {
        if let commentId = CommentLink.commentId(from: url) {
            openComments(focus: commentId)
            return
        }
        if let atom = AtomLink.parse(url) {
            model?.editAtom(blockIdentity: atom.block, type: atom.type, index: atom.index)
            return
        }
        switch ContentLinkRouter.destination(for: url, serverURL: session.server?.url) {
        case .page(let slugId, let anchor):
            if [state.value?.slugId, state.value?.id, selection.pageId].contains(slugId) {
                // This page: scroll, never push a second copy of it.
                if let anchor { scroll(to: anchor) }
            } else {
                navigation.open(PageSelection(pageId: slugId))
            }
        case .databaseEntry(let basePageId, let rowId):
            navigation.open(PageSelection(pageId: basePageId, rowId: rowId))
        case .comment(let slugId, let commentId):
            if [state.value?.slugId, state.value?.id, selection.pageId].contains(slugId) {
                openComments(focus: commentId)
            } else {
                navigation.open(PageSelection(pageId: slugId, commentId: commentId))
            }
        case .anchor(let anchor):
            // Footnote reference while editing: jump into the footnote text, like a double-click in the web editor.
            if model?.focusFootnote(dataId: anchor) == true { return }
            scroll(to: anchor)
        case .user:
            break
        case .external(let external):
            outside(external)
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
