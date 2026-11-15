import SwiftUI

@main
struct DiderotApp: App {
    @State private var session = AppSession()
    @State private var navigation = AppNavigation()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(navigation)
        }
    }
}
