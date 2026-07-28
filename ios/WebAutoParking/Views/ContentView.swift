import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    /// Only create WKWebViews for tabs the user has opened (avoids 3× WebViews at once).
    @State private var activatedTabs: Set<Int> = [0]

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                GarageListView()
            }
            .tabItem {
                Label("Garages", systemImage: "parkingsign.circle.fill")
            }
            .tag(0)

            webTab(tag: 1, title: "Find Parking", tabLabel: "Find", systemImage: "magnifyingglass", url: FixedDurationURLs.search)
            webTab(tag: 2, title: "Browse", tabLabel: "Browse", systemImage: "mappin.and.ellipse", url: FlexibleDurationURLs.home)
            webTab(tag: 3, title: "Zone Parking", tabLabel: "Zone", systemImage: "number.circle", url: FixedDurationURLs.zoneStart)
        }
        .onChange(of: selectedTab) { _, tab in
            activatedTabs.insert(tab)
            AppLog.log("Tab selected \(tab)")
        }
    }

    @ViewBuilder
    private func webTab(tag: Int, title: String, tabLabel: String, systemImage: String, url: URL) -> some View {
        NavigationStack {
            Group {
                if activatedTabs.contains(tag) {
                    ParkingWebView(title: title, url: url)
                } else {
                    Color.clear
                }
            }
        }
        .tabItem {
            Label(tabLabel, systemImage: systemImage)
        }
        .tag(tag)
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
