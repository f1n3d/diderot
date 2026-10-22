import SwiftUI

@main
struct DiderotApp: App {
    /// Only for UIKit menus (the editor's selection menu), see `AppDelegate`.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
