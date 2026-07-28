import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                GarageListView()
            }
            .tabItem {
                Label("Garages", systemImage: "parkingsign.circle.fill")
            }

            NavigationStack {
                ParkingWebView(
                    title: "Find Parking",
                    url: FixedDurationURLs.search
                )
            }
            .tabItem {
                Label("Find", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ParkingWebView(
                    title: "Browse",
                    url: FlexibleDurationURLs.home
                )
            }
            .tabItem {
                Label("Browse", systemImage: "mappin.and.ellipse")
            }

            NavigationStack {
                ParkingWebView(
                    title: "Zone Parking",
                    url: FixedDurationURLs.zoneStart
                )
            }
            .tabItem {
                Label("Zone", systemImage: "number.circle")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
