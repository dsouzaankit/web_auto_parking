import CoreLocation
import SwiftUI

/// ParkMobile `/search` → nearest zone → `/zone/start` (manual zone-id submit) → checkout prep.
struct ParkMobileZoneView: View {
    @StateObject private var location = LocationService()
    /// Local copy so SessionPreferences publishes (Garage tab / picker) do not rebuild the WebView owner.
    @State private var zoneMaxDurationMinutes = SessionPreferences.shared.zoneMaxDurationMinutes
    @State private var locationReady = false
    @State private var statusText = "Getting location…"

    private var prefillContext: PrefillContext {
        PrefillContext(
            mode: .parkMobileZone,
            latitude: location.coordinate?.latitude,
            longitude: location.coordinate?.longitude,
            maxDurationMinutes: zoneMaxDurationMinutes,
            zoneAutomationEnabled: true
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if locationReady {
                    ParkingWebView(
                        title: "ParkMobile Zone",
                        url: FixedDurationURLs.search,
                        prefillContext: prefillContext
                    )
                    .id("zone-parking-webview")
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
            .safeAreaInset(edge: .top, spacing: 0) {
                ZoneDurationPickerBar(minutes: $zoneMaxDurationMinutes)
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
                            zoneMaxDurationMinutes
                        )
                    )
                } else {
                    statusText = location.lastError
                        ?? "No GPS fix yet — opening Zone (native geo stub may arrive later)"
                    AppLog.log(
                        "Zone tab opening without GPS fix status=\(location.authorizationStatus.rawValue) " +
                        "duration=\(zoneMaxDurationMinutes)m"
                    )
                }
                locationReady = true
            }
        }
    }
}

/// Owns SessionPreferences observation so picker churn cannot remount the Zone WKWebView.
private struct ZoneDurationPickerBar: View {
    @Binding var minutes: Int
    @ObservedObject private var sessionPrefs = SessionPreferences.shared

    var body: some View {
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
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear {
            minutes = sessionPrefs.zoneMaxDurationMinutes
        }
        .onChange(of: sessionPrefs.zoneMaxDurationMinutes) { _, newValue in
            if minutes != newValue {
                minutes = newValue
            }
        }
    }
}

#Preview {
    ParkMobileZoneView()
}
