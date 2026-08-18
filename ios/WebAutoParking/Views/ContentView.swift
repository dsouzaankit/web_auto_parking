import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack {
                GarageListView()
            }
            .tabItem {
                Label("Garages", systemImage: "building.2")
            }

            ParkMobileZoneView()
                .tabItem {
                    Label("Zone", systemImage: "mappin.and.ellipse")
                }

            ParkingSessionsView()
                .tabItem {
                    Label("Z. History", systemImage: "clock.arrow.circlepath")
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
