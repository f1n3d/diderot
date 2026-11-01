import SwiftUI

/// The app's license and those of the third-party code it ships, from `ThirdPartyNotices.json` (written by
/// Tools/third-party-notices.mjs, like THIRD_PARTY_NOTICES.md).
struct LicensesView: View {
    struct Notices: Decodable {
        let sections: [Group]
    }

    struct Group: Decodable, Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// Packages that share one license text.
    struct Entry: Decodable, Identifiable {
        let packages: [String]
        let license: String
        let text: String
        var id: String { packages.joined(separator: ",") }
    }

    /// Read once (110 KB of JSON): as a property of the view, on every pass of the settings screen.
    static let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Notices.self, from: $0) }

    var body: some View {
        if let notices = Self.notices {
            list(notices)
        } else {
            // An empty list said nothing.
            ContentUnavailableView("Licenses unavailable", systemImage: "doc.text",
                                   description: Text("The list of licenses couldn't be read."))
                .navigationTitle("Licenses")
        }
    }

    private func list(_ notices: Notices) -> some View {
        List(notices.sections) { group in
            Section(LocalizedStringKey(group.title)) {
                ForEach(group.entries) { entry in
                    NavigationLink {
                        ScrollView {
                            Text(entry.text)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(entry.packages.count == 1 ? entry.packages[0] : group.title)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.packages.joined(separator: ", "))
                                .lineLimit(3)
                            Text(entry.license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Licenses")
    }
}
