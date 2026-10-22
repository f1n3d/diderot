import SwiftUI
import DocmostKit

/// Inline search results (Search tab home, space view): a card that replaces the content while a query is entered.
struct SearchResultsCard: View {
    @Bindable var search: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Results")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Titles Only", systemImage: "textformat", isOn: $search.titleOnly)
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityIdentifier("search-titles-only")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            results
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var results: some View {
        if let errorMessage = search.errorMessage {
            ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                .padding(.vertical, 20)
        } else if search.results.isEmpty {
            if search.isSearching {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            } else {
                ContentUnavailableView.search(text: search.trimmedQuery)
                    .padding(.vertical, 20)
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(search.results) { result in
                    NavigationLink(value: PageSelection(pageId: result.id, title: result.title)) {
                        SearchResultRow(result: result)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("search-result-\(result.id)")
                    if result.id != search.results.last?.id || search.hasMore {
                        Divider().padding(.leading, 16)
                    }
                }
                if search.hasMore {
                    Button {
                        Task { await search.loadMore() }
                    } label: {
                        HStack {
                            Text("Load More")
                            Spacer()
                            if search.isSearching { ProgressView() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .disabled(search.isSearching)
                }
            }
            .padding(.bottom, 6)
        }
    }
}
