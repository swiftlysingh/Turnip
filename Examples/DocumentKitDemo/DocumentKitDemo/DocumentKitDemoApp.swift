import SwiftUI

@main
struct DocumentKitDemoApp: App {
    var body: some Scene {
        WindowGroup("DocumentKit Demo") {
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
