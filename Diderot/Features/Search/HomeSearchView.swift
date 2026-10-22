import SwiftUI

/// Search tab: the home screen with the search field in the tab bar.
struct HomeSearchView: View {
    @Environment(AppSession.self) private var session
    @State private var search = SearchModel(query: DebugLaunch.query ?? "")

    var body: some View {
        @Bindable var search = search
        HomeView(search: search)
            .searchable(text: $search.query, prompt: Text("Search pages"))
            .autocorrectionDisabled()
            .task(id: search.key) {
                search.session = session
                await search.run()
            }
    }
}
