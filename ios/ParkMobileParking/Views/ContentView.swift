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
                ParkMobileWebView(
                    title: "ParkMobile Find",
                    url: ParkMobileURLs.search
                )
            }
            .tabItem {
                Label("ParkMobile", systemImage: "magnifyingglass")
            }

            NavigationStack {
                ParkMobileWebView(
                    title: "SpotHero",
                    url: SpotHeroURLs.home
                )
            }
            .tabItem {
                Label("SpotHero", systemImage: "mappin.and.ellipse")
            }

            NavigationStack {
                ParkMobileWebView(
                    title: "Zone Parking",
                    url: ParkMobileURLs.zoneStart
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
