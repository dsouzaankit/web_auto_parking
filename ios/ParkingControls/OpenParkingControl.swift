import AppIntents
import SwiftUI
import WidgetKit

/// Control Center control with SF Symbol icon (system Open App often blanks sideloaded app icons).
struct OpenParkingControl: ControlWidget {
    static let kind = "com.webautoparking.app.OpenParking"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenParkingIntent()) {
                Label("Parking", systemImage: "parkingsign")
            }
        }
        .displayName("Parking")
        .description("Open the Parking app.")
    }
}
