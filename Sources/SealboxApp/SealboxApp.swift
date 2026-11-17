import SwiftUI

// PhoneVM home-screen shell (0.1.3): a static iPhone home screen.
// No navigation, no gestures, no state, no storage, no network.
// Every icon is a plain view — tapping one does nothing.
@main
struct SealboxApp: App {
    var body: some Scene {
        WindowGroup {
            HomeScreenView()
                .preferredColorScheme(.dark)
        }
    }
}
