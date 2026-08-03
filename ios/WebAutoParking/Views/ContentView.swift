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
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
