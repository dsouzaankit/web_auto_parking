import SwiftUI

struct GarageListView: View {
    @EnvironmentObject private var store: GarageStore
    @ObservedObject private var sessionPrefs = SessionPreferences.shared
    @State private var showingAdd = false
    @State private var selectedGarage: Garage?
    @State private var sessionURL: URL?
    @State private var sessionSummary = ""
    @State private var lanEnabled = LANLogServer.isEnabled
    @State private var lanURLSummary = ""

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                Picker("Fixed duration", selection: $sessionPrefs.durationHours) {
                    Text("3 hours").tag(3)
                    Text("4 hours").tag(4)
                }
                .pickerStyle(.segmented)

                Text(sessionSummary)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } header: {
                Text("Session")
            } footer: {
                Text("Starts on the next 15-minute mark. Fixed-duration providers lock the selected length; flexible providers keep any free extra time from the rate package. Default also set via BookingConfig.json → sessionDurationHours.")
            }

            Section {
                Toggle(LANLogServer.lanServerToggleTitle, isOn: $lanEnabled)
                    .onChange(of: lanEnabled) { _, enabled in
                        LANLogServer.applyEnabled(enabled)
                        refreshLANSummary()
                    }
                if lanEnabled {
                    Text(lanURLSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("LAN logs")
            } footer: {
                Text("Same Wi‑Fi as your PC. Prefer the IP URL on Windows. Port \(LANLogServer.defaultPort) · /logs.txt")
            }

            Section {
                ForEach(store.garages) { garage in
                    Button {
                        let url = garage.reservationURL(
                            from: .now,
                            durationHours: sessionPrefs.durationHours
                        )
                        AppLog.log("Open garage \(garage.name) id=\(garage.facilityID) provider=\(garage.provider.rawValue) url=\(url.absoluteString)")
                        sessionURL = url
                        selectedGarage = garage
                    } label: {
                        GarageRow(garage: garage)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.remove(garage)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete(perform: store.remove)
            } header: {
                Text("Saved Garages")
            }
        }
        .navigationTitle("Parking")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                AddGarageView()
            }
        }
        .navigationDestination(item: $selectedGarage) { garage in
            ParkingWebView(
                title: garage.name,
                url: sessionURL ?? garage.reservationURL(
                    from: .now,
                    durationHours: sessionPrefs.durationHours
                )
            )
        }
        .onReceive(timer) { _ in
            refreshSummary()
            refreshLANSummary()
        }
        .onAppear {
            refreshSummary()
            lanEnabled = LANLogServer.isEnabled
            if lanEnabled {
                LANLogServer.ensureRunning()
            }
            refreshLANSummary()
        }
        .onChange(of: sessionPrefs.durationHours) { _, _ in
            refreshSummary()
        }
    }

    private func refreshSummary() {
        sessionSummary = SessionWindow.displayRange(durationHours: sessionPrefs.durationHours)
    }

    private func refreshLANSummary() {
        let urls = LANLogServer.displayLANURLs
        if let ip = urls.ip {
            lanURLSummary = ip
            if let host = urls.host {
                lanURLSummary += "\n\(host)"
            }
        } else if let host = urls.host {
            lanURLSummary = host
        } else if lanEnabled {
            lanURLSummary = "Starting… allow Local Network if prompted"
        } else {
            lanURLSummary = ""
        }
    }
}

private struct GarageRow: View {
    let garage: Garage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(garage.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(garage.provider.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !garage.address.isEmpty {
                Text(garage.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("ID \(garage.facilityID)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        GarageListView()
    }
    .environmentObject(GarageStore())
}
