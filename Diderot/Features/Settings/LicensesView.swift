import SwiftUI

/// The app's license and those of the third-party code it ships, from `ThirdPartyNotices.json` (written by
/// Tools/third-party-notices.mjs, like THIRD_PARTY_NOTICES.md).
struct LicensesView: View {
    private struct Notices: Decodable {
        let sections: [Group]
    }

    private struct Group: Decodable, Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// Packages that share one license text.
    private struct Entry: Decodable, Identifiable {
        let packages: [String]
        let license: String
        let text: String
        var id: String { packages.joined(separator: ",") }
    }

    private let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Notices.self, from: $0) }

    var body: some View {
        List(notices?.sections ?? []) { group in
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
