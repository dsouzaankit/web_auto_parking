import SwiftUI
import UIKit

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
                    // Keep screen awake while Parking is foregrounded (checkout can take minutes).
                    UIApplication.shared.isIdleTimerDisabled = true
                    // Start after a scene is visible so Local Network permission can prompt.
                    LANLogServer.ensureRunning()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = true
                        LANLogServer.ensureRunning()
                    case .inactive, .background:
                        UIApplication.shared.isIdleTimerDisabled = false
                    @unknown default:
                        break
                    }
                }
        }
    }
}
