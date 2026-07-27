import SwiftUI

@main
struct ParkMobileParkingApp: App {
    @StateObject private var store = GarageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
