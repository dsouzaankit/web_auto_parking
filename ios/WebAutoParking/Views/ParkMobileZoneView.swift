import CoreLocation
import SwiftUI

/// ParkMobile `/search` → nearest zone → `/zone/start` (manual zone-id submit) → checkout prep.
struct ParkMobileZoneView: View {
    @StateObject private var location = LocationService()
    @ObservedObject private var sessionPrefs = SessionPreferences.shared
    @State private var locationReady = false
    @State private var statusText = "Getting location…"

    private var prefillContext: PrefillContext {
        PrefillContext(
            mode: .parkMobileZone,
            latitude: location.coordinate?.latitude,
            longitude: location.coordinate?.longitude,
            maxDurationMinutes: sessionPrefs.zoneMaxDurationMinutes,
            zoneAutomationEnabled: true
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Duration", selection: $sessionPrefs.zoneMaxDurationMinutes) {
                        ForEach(ZoneDurationOption.allCases) { option in
                            Text(option.shortLabel).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Zone duration")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Group {
                    if locationReady {
                        ParkingWebView(
                            title: "ParkMobile Zone",
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
            }
            .task {
                statusText = "Waiting for location permission…"
                location.requestWhenInUseIfNeeded()
                if let coord = await location.currentCoordinate(timeoutSeconds: 12) {
                    statusText = String(
                        format: "Location ready (%.4f, %.4f)",
                        coord.latitude,
                        coord.longitude
                    )
                    AppLog.log(
                        String(
                            format: "Zone tab opening with lat=%.5f lng=%.5f duration=%dm",
                            coord.latitude,
                            coord.longitude,
                            sessionPrefs.zoneMaxDurationMinutes
                        )
                    )
                } else {
                    statusText = location.lastError
                        ?? "No GPS fix yet — opening Zone (native geo stub may arrive later)"
                    AppLog.log(
                        "Zone tab opening without GPS fix status=\(location.authorizationStatus.rawValue) " +
                        "duration=\(sessionPrefs.zoneMaxDurationMinutes)m"
                    )
                }
                locationReady = true
            }
        }
    }
}

#Preview {
    ParkMobileZoneView()
}
