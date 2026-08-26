import SwiftUI

@main
struct TurnipDemoApp: App {
    var body: some Scene {
        WindowGroup("Turnip Demo") {
#if os(macOS)
            ContentView()
#else
            IOSContentView()
#endif
        }
#if os(macOS)
        .defaultSize(width: 1_100, height: 720)
#endif
    }
}
