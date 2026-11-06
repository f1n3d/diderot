import SwiftUI

/// Calls `action` once this view is in a window and the push or presentation that brought it there has ended, at once
/// without one. Focus, a sheet or a scroll asked for mid-transition is dropped or lands wrong; a fixed wait for the
/// transition was too short on a slow device. Goes in a `background`, and calls again each time the view comes back
/// into a window (a pushed view popped), so what it starts happens once by a flag of its own.
struct AfterTransition: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> SignalView {
        SignalView(action: action)
    }

    func updateUIView(_ view: SignalView, context: Context) {
        view.action = action
    }

    final class SignalView: UIView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            // Not the view it sits behind: an identifier given to that one would land here too.
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Next run loop: by then the view controller showing this view knows its transition.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                guard let coordinator = self.viewController?.transitionCoordinator else { return self.action() }
                let queued = coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    // A cancelled transition (a swipe back let go) took this view out again.
                    guard let self, !context.isCancelled, self.window != nil else { return }
                    self.action()
                }
                if !queued { self.action() }
            }
        }

        /// The view controller this view is shown in; it answers for its parents' transitions too.
        private var viewController: UIViewController? {
            var responder = next
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
    }
}

extension ScrollViewProxy {
    /// Scrolls a list to the row `id` and highlights it briefly: a comment or a field opened from elsewhere.
    @MainActor
    func reveal<ID: Hashable>(_ id: ID, highlighting highlighted: Binding<ID?>) async {
        withAnimation {
            scrollTo(id, anchor: .top)
            highlighted.wrappedValue = id
        }
        try? await Task.sleep(for: .seconds(1.6))
        guard highlighted.wrappedValue == id else { return }
        withAnimation(.easeOut(duration: 0.6)) { highlighted.wrappedValue = nil }
    }
}
