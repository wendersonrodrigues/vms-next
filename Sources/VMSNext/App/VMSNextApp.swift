import SwiftUI

@main
struct VMSNextApp: App {
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup("VMS Next") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 600)
        }
    }
}
