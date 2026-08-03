import CoreLocation
import SwiftUI

/// ParkMobile `/search` → nearest zone → `/zone/start` → checkout prep (pauses only on submit errors).
struct ParkMobileZoneView: View {
    @StateObject private var location = LocationService()
    @State private var locationReady = false
    @State private var statusText = "Getting location…"

    private var prefillContext: PrefillContext {
        PrefillContext(
            mode: .parkMobileZone,
            latitude: location.coordinate?.latitude,
            longitude: location.coordinate?.longitude,
            maxDurationMinutes: 100,
            zoneAutomationEnabled: true
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationReady {
                    ParkingWebView(
                        title: "ParkMobile Zone",
                        // SPA's own /api/zones/search works here; direct fetch from /zone/start gets 422.
                        url: FixedDurationURLs.search,
                        prefillContext: prefillContext
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task {
                statusText = "Waiting for location permission…"
                location.requestWhenInUseIfNeeded()
                // Prefer a real fix before loading /search — WKWebView geo is flaky; stub uses this.
                if let coord = await location.currentCoordinate(timeoutSeconds: 12) {
                    statusText = String(
                        format: "Location ready (%.4f, %.4f)",
                        coord.latitude,
                        coord.longitude
                    )
                    AppLog.log(
                        String(format: "Zone tab opening with lat=%.5f lng=%.5f",
                               coord.latitude, coord.longitude)
                    )
                } else {
                    statusText = location.lastError
                        ?? "No GPS fix yet — opening Zone (native geo stub may arrive later)"
                    AppLog.log("Zone tab opening without GPS fix status=\(location.authorizationStatus.rawValue)")
                }
                locationReady = true
            }
        }
    }
}

#Preview {
    ParkMobileZoneView()
}
