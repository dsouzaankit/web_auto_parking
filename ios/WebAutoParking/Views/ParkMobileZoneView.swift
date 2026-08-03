import CoreLocation
import SwiftUI

/// ParkMobile `/zone/start` → auto Continue through checkout prep (pauses only on submit errors).
struct ParkMobileZoneView: View {
    @StateObject private var location = LocationService()
    @State private var locationReady = false

    var body: some View {
        NavigationStack {
            Group {
                if locationReady {
                    ParkingWebView(
                        title: "ParkMobile Zone",
                        url: FixedDurationURLs.zoneStart,
                        prefillContext: PrefillContext(
                            mode: .parkMobileZone,
                            latitude: location.coordinate?.latitude,
                            longitude: location.coordinate?.longitude,
                            maxDurationMinutes: 100,
                            zoneAutomationEnabled: true
                        )
                    )
                } else {
                    ProgressView("Getting location…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                location.requestWhenInUseIfNeeded()
                _ = await location.currentCoordinate()
                locationReady = true
            }
        }
    }
}

#Preview {
    ParkMobileZoneView()
}
