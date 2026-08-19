import SwiftUI

@main
struct WebAutoParkingApp: App {
    @StateObject private var store = GarageStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLog.clear()
        AppLog.ensureReady()
        XHRCapture.clear()
        HTMLCapture.clear()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.log("App launch v\(version) build \(build) prefillAuto=\(BookingFormPrefill.autoInjectEnabled)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    // Start after a scene is visible so Local Network permission can prompt.
                    LANLogServer.ensureRunning()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        LANLogServer.ensureRunning()
                    }
                }
        }
    }
}
