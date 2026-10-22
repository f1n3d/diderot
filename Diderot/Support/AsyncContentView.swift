import SwiftUI
import DocmostKit

/// A view's loading state.
enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(any Error)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

/// Shows a spinner, an error with "Try Again", or the content.
struct AsyncContentView<Value: Sendable, Content: View>: View {
    let state: LoadState<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ErrorStateView(error: error, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}

struct ErrorStateView: View {
    let error: any Error
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.userMessage)
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

extension Error {
    /// User-facing message; API errors supply their own wording.
    var userMessage: String {
        if let apiError = self as? APIError {
            return apiError.userMessage
        }
        return localizedDescription
    }
}
