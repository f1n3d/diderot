import SwiftUI

/// Centers the page's active block above the keyboard in one motion with it, keeps the caret visible while typing, and
/// scrolls to find's current match. The page turns SwiftUI's keyboard avoidance off (`ignoresSafeArea(.keyboard)`): it
/// jumped before the centering ran. On the page's scroll view, whose height it reports for the trailing space.
struct CentersAboveKeyboard: ViewModifier {
    /// A binding: the keyboard's callback outlives this value and needs the page's model of the time.
    @Binding var model: DocumentModel?
    let find: PageFind
    @Binding var position: ScrollPosition
    /// Height of the page view below the navigation bar (ignoring the keyboard).
    @Binding var scrollHeight: CGFloat
    @State private var centering = CenteringState()
    @State private var keyboard = KeyboardObserver()

    func body(content: Content) -> some View {
        content
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
            .onChange(of: find.revealRequest) { _, _ in revealFindMatch() }
            .onAppear {
                keyboard.start { top, duration in keyboardChanged(top: top, duration: duration) }
            }
            .onDisappear { keyboard.stop() }
    }

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


    private nonisolated struct ViewGeometry: Equatable, Sendable {
        let frame: CGRect
        let safeTop: CGFloat
        let safeBottom: CGFloat
    }

    private nonisolated struct ScrollMetrics: Equatable, Sendable {
        let offset: CGFloat
        let insetTop: CGFloat
    }

    // MARK: - The active block

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
        // Right after the tap the editor still changes (its height); keep re-centering it for that long.
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

    /// The active editor changed size or position (line wrap, slash/mention menu).
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

    // MARK: - Find's current match

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
        let bottom = min(find.barTop ?? .infinity, centering.keyboardTop ?? .infinity, centering.frame.maxY)
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
}
