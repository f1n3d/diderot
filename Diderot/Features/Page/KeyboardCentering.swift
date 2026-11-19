import SwiftUI

/// Centers the page's active block above the keyboard in one motion with it, keeps the caret visible while typing, and
/// scrolls to find's current match or a comment's passage. The page turns SwiftUI's keyboard avoidance off
/// (`ignoresSafeArea(.keyboard)`): it jumped before the centering ran. On the page's scroll view, whose height it
/// reports for the trailing space.
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
                // Never scroll against the user, also not later for find's match or a comment's passage.
                centering.userScrolling = phase == .interacting || phase == .decelerating
                if centering.userScrolling {
                    centering.findTarget = nil
                    find.endPassage()
                }
                if phase != .animating { centering.target = nil }
                if phase == .idle { passageSettled() }
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
            .onChange(of: find.currentFrame.map { FindFrame(ref: $0.ref, frame: $0.frame) }) { _, _ in findFrameChanged() }
            .onChange(of: find.barRise) { _, _ in findBarRose() }
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
        var hideTask: Task<Void, Never>?
        /// Find's match or a comment's passage to center once its block reports its frame (built after the scroll there).
        var findTarget: FindMatch?
        /// The target the page jumps to and asks for again until its block reports (`jump`), and which chain of jumps
        /// is the one that goes on: a target asked for anew starts another.
        var jumpTarget: FindMatch?
        var jumpChain = 0
        /// The passage shown was centered again once after a scroll settled (`passageSettled`): once is enough, and where
        /// the page can't get there (its end), more would scroll without end.
        var passageRecentered = false

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

    private struct FindFrame: Equatable {
        let ref: NodeRef
        let frame: CGRect
    }

    // MARK: - The active block

    /// A block became active: center it above the keyboard in one motion as the keyboard slides in (its notification
    /// triggers that in `keyboardChanged`). With the keyboard already up, or none docking, the placed caret does it
    /// (`cursorPlaced`): started right away, the motion ran while the editor was built, dropped frames, and restarted
    /// when the editor settled. After Return or Backspace the page keeps its place instead, as in other editors.
    private func activeBlockChanged() {
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
        guard changed else { return }
        // The keyboard that comes back with the editor once the comments are gone keeps a comment's passage in sight,
        // not the caret. Not yet measured, its block centers it with this keyboard once it reports (`findFrameChanged`).
        if let passage = find.passage {
            if let frame = frame(of: passage) { centerFindMatch(frame, duration: duration) }
            return
        }
        guard model?.active != nil else { return }
        if centering.isCentering {
            center(duration: duration)
        } else {
            reveal(duration: duration)
        }
    }

    /// The active editor changed size or position (line wrap, slash/mention menu).
    private func activeFrameChanged() {
        guard let model, model.active != nil, model.activeBlockFrame.height > 0 else { return }
        // A comment's passage in the edited block, measured once the page went there; elsewhere the caret waits.
        if find.passage != nil {
            findFrameChanged()
            return
        }
        if centering.isCentering {
            // While the keyboard is still coming, its notification does the centering; the placed caret starts it
            // (`cursorPlaced`), with the keyboard up or none docking.
            if model.cursorRequest == nil { center(duration: 0.35) }
        } else if !model.isSwitchingByTyping {
            reveal(duration: 0.2)
        }
    }

    /// The new editor has focus and its caret: the work of the switch is done, so the centering runs without dropping
    /// frames (started with the editor's first frame, it stuttered for about 150 ms). A keyboard docking at the bottom
    /// reported itself with the focus; without one docked by now none comes (a hardware keyboard, a floating one), and
    /// the editor is centered in the whole height. Without centering (Return, Backspace) the caret only stays visible.
    private func cursorPlaced() {
        // A comment's passage being shown keeps the page.
        guard find.passage == nil else { return }
        if centering.isCentering {
            center(duration: 0.35)
        } else {
            reveal(duration: 0.2)
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

    // MARK: - Find's current match, a comment's passage

    /// Goes to find's current match, or to a comment's passage ("Show on Page"): if its block is built, it reports its
    /// frame once it holds the target, and the target is centered above the find bar or the keyboard; otherwise the page
    /// first scrolls to the enclosing top-level block, which builds it and so reports it (`findFrameChanged`).
    private func revealFindMatch() {
        guard let target = find.revealTarget else { return }
        centering.findTarget = target
        centering.passageRecentered = false
        // Next run loop: by then this update has laid out the blocks, and a built one holding the target has reported.
        DispatchQueue.main.async {
            guard centering.findTarget == target, find.revealTarget == target else { return }
            if let frame = frame(of: target) {
                centering.findTarget = nil
                centerFindMatch(frame)
            } else {
                jump(to: target)
            }
        }
    }

    /// Jumps to the target's top-level block, which builds the target's block and so makes it report its frame. A jump
    /// asked for while an animated scroll is on its way doesn't always arrive. With "Versteckt…" typed at a key per
    /// frame, the page was on its way to the match of "Ver" when the jump to the one match left was asked for: in 5 of
    /// 47 searches it then stood at its top, the block not built, with "1 of 1" in the bar (test45, November 19, 2026).
    /// With the centering asked for on the next run loop (`findFrameChanged`), which is how the scroll to "Ver" starts
    /// too, no jump was lost in 98 more such searches. Why either is so isn't known: where the block hasn't reported
    /// half a second later, the page is asked again (`askForBlock`). One such chain per target: each key of the query
    /// asks for its target anew.
    private func jump(to target: FindMatch) {
        guard centering.jumpTarget != target else { return }
        centering.jumpTarget = target
        centering.jumpChain += 1
        askForBlock(of: target, chain: centering.jumpChain)
    }

    /// One jump of the chain, and half a second later the next, three more at most, unless the block has reported, find
    /// has another target, or the user scrolled (which ends `findTarget`). Asked for the same place again, the page
    /// does nothing, as it did for every further key: it is first told to stay where it is, which is another place to
    /// it and ends a scroll still on its way, and asked on the next run loop, from rest as a first jump is.
    private func askForBlock(of target: FindMatch, chain: Int, again attempt: Int = 0) {
        var lost = false
        #if DEBUG
        lost = attempt == 0 && DebugLaunch.losesFindJump
        #endif
        if !lost { position.scrollTo(id: target.topLevel.anchorId, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard centering.jumpTarget == target, centering.jumpChain == chain else { return }
            guard attempt < 3, centering.findTarget == target, find.revealTarget == target, frame(of: target) == nil else {
                centering.jumpTarget = nil
                return
            }
            centering.target = nil
            position.scrollTo(y: centering.current)
            DispatchQueue.main.async {
                guard centering.jumpTarget == target, centering.jumpChain == chain else { return }
                askForBlock(of: target, chain: chain, again: attempt + 1)
            }
        }
    }

    /// The block holding find's target reported its frame: centers it if the page is on its way there. On the next run
    /// loop: asked for within the update that brought the frame, the one of the jump that built the block, the scroll
    /// never started, as `findBarRose` found. The page stayed where the jump had put the top-level block: a point or two
    /// off for a short block, and for the last item of a list of 40 with the match below the keyboard (test107).
    private func findFrameChanged() {
        guard let target = centering.findTarget, find.revealTarget == target, frame(of: target) != nil else { return }
        centering.findTarget = nil
        DispatchQueue.main.async {
            guard find.revealTarget == target, !centering.userScrolling, let frame = frame(of: target) else { return }
            centerFindMatch(frame)
        }
    }

    /// The frame of the target's block in document coordinates, once it is built: the editor's while the block is
    /// edited (a comment's passage can be there), else the one the block reports.
    private func frame(of target: FindMatch) -> CGRect? {
        if let model, model.active?.ref == target.ref {
            return model.activeBlockFrame.height > 0 ? model.activeBlockFrame : nil
        }
        guard let current = find.currentFrame, current.ref == target.ref else { return nil }
        return current.frame
    }

    private func centerFindMatch(_ frame: CGRect, duration: Double = 0.3) {
        guard let free = freeRange else { return }
        scroll(to: centering.scrollTarget(placing: frame.midY, atWindowY: (free.lowerBound + free.upperBound) / 2), duration: duration)
    }

    /// Where find's target is centered, in window coordinates: below the navigation bar, above the find bar and the
    /// keyboard.
    private var freeRange: ClosedRange<CGFloat>? {
        let top = centering.frame.minY
        let bottom = min(find.barTop ?? .infinity, centering.keyboardTop ?? .infinity, centering.frame.maxY)
        return bottom - top > 60 ? top...bottom : nil
    }

    /// The find bar rose on the keyboard that came up under it: the field took its focus back after the user scrolled
    /// the keyboard away. A current match that was in sight above the bar's place before, and isn't above its new one,
    /// is centered there, as when find went to it. One the user scrolled out of sight stays where it is.
    private func findBarRose() {
        guard find.passage == nil, let match = find.currentMatch, !centering.userScrolling, let frame = frame(of: match),
              let free = freeRange, let before = find.barTopBeforeRise
        else { return }
        // Where a scroll still on its way will have put the match (to the next match, say), as `reveal` counts.
        let shift = (centering.pendingTarget ?? centering.current) - centering.current
        let top = centering.windowY(of: frame.minY) - shift
        let bottom = centering.windowY(of: frame.maxY) - shift
        guard top >= free.lowerBound, bottom <= before, bottom > free.upperBound else { return }
        // Next run loop: asked for within the update that moved the bar, the scroll never started.
        DispatchQueue.main.async {
            guard find.currentMatch == match, find.passage == nil, !centering.userScrolling else { return }
            centerFindMatch(frame)
        }
    }

    /// A scroll ended while a comment's passage is shown: if something else moved the page meanwhile, the passage is
    /// centered again. The editor taking its focus back once the comments are gone undid the first centering.
    private func passageSettled() {
        guard let passage = find.passage, !centering.userScrolling, let frame = frame(of: passage), let free = freeRange
        else { return }
        let top = centering.windowY(of: frame.minY)
        let bottom = centering.windowY(of: frame.maxY)
        guard top < free.lowerBound || bottom > free.upperBound, !centering.passageRecentered else { return }
        centering.passageRecentered = true
        centerFindMatch(frame)
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
