import SwiftUI

/// Brief feedback at the bottom edge that dismisses itself. VoiceOver reads it out, and while VoiceOver runs it stays
/// until dismissed (double-tap): it is the app's main way to say what failed, and 2.5 s were too short to find it.
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAction { self.message = nil }
                        .accessibilityHint(Text("Double-tap to dismiss."))
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message).post()
                            guard !voiceOver else { return }
                            try? await Task.sleep(for: .seconds(2.5))
                            guard !Task.isCancelled else { return }
                            self.message = nil
                        }
                }
            }
            .animation(.default, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
