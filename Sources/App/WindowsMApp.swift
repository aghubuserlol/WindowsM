import SwiftUI

@main
struct WindowsMApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            WizardView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // single-window wizard
        }
    }
}
