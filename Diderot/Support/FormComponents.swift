import SwiftUI

/// Red error line in a form; shows nothing without a message.
struct FormErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }
}

/// Label of a submit button with a trailing spinner while it works.
struct BusyLabel: View {
    let title: LocalizedStringKey
    let isBusy: Bool

    var body: some View {
        HStack {
            Text(title)
            if isBusy {
                Spacer()
                ProgressView()
            }
        }
    }
}
