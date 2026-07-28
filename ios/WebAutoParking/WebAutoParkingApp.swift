import SwiftUI

@main
struct WebAutoParkingApp: App {
    @StateObject private var store = GarageStore()

    init() {
        AppLog.ensureReady()
        AppLog.log("App launch")
        LANLogServer.ensureRunning()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
