import SwiftUI

/// Opens a Docmost web URL (typed or from the clipboard) in the app.
struct OpenLinkSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://wiki.example.com/s/…/p/…", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(open)
                    PasteButton(payloadType: URL.self) { urls in
                        if let url = urls.first {
                            text = url.absoluteString
                            open()
                        }
                    }
                    .buttonBorderShape(.capsule)
                } header: {
                    Text("Page link")
                } footer: {
                    Text("Links to pages on \(session.server?.url.host() ?? String(localized: "your server")) open directly in the app.")
                }
                FormErrorSection(message: errorMessage)
            }
            .navigationTitle("Open Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Open", action: open).disabled(text.isEmpty) }
            }
        }
    }

    private func open() {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = String(localized: "That doesn't look like a link.")
            return
        }
        if appNavigation.handle(url, session: session) {
            dismiss()
        } else {
            errorMessage = String(localized: "This link doesn't point to a page on your Docmost server.")
        }
    }
}
