import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    /// Only create WKWebViews for tabs the user has opened (avoids multiple WebViews at once).
    @State private var activatedTabs: Set<Int> = [0]
    private let searchBrands = WebBrandOption.findBrands

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                GarageListView()
            }
            .tabItem {
                Label("Garages", systemImage: "parkingsign.circle.fill")
            }
            .tag(0)

            brandedWebTab(
                tag: 1,
                title: "Find Parking",
                tabLabel: "Find",
                systemImage: "magnifyingglass",
                brands: searchBrands
            )
            webTab(tag: 2, title: "Zone Parking", tabLabel: "Zone", systemImage: "number.circle", url: FixedDurationURLs.zoneStart)
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

    @ViewBuilder
    private func brandedWebTab(
        tag: Int,
        title: String,
        tabLabel: String,
        systemImage: String,
        brands: [WebBrandOption]
    ) -> some View {
        NavigationStack {
            Group {
                if activatedTabs.contains(tag) {
                    MultiBrandWebTabView(title: title, brands: brands)
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

private struct WebBrandOption: Identifiable, Hashable {
    let id: String
    let label: String
    let webViewTitle: String
    let url: URL

    private static let spotHeroSearch = URL(string: "https://spothero.com/search")!

    static let findBrands: [WebBrandOption] = [
        .init(id: "parkmobile-search", label: "ParkMobile", webViewTitle: "ParkMobile", url: FixedDurationURLs.search),
        .init(id: "spothero-search", label: "SpotHero", webViewTitle: "SpotHero", url: spotHeroSearch)
    ]
}

private struct MultiBrandWebTabView: View {
    let title: String
    let brands: [WebBrandOption]
    @State private var selectedBrandID: String

    init(title: String, brands: [WebBrandOption]) {
        self.title = title
        self.brands = brands
        _selectedBrandID = State(initialValue: brands.first?.id ?? "")
    }

    private var selectedBrand: WebBrandOption? {
        brands.first(where: { $0.id == selectedBrandID }) ?? brands.first
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("\(title) provider", selection: $selectedBrandID) {
                ForEach(brands) { brand in
                    Text(brand.label).tag(brand.id)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            if let selectedBrand {
                ParkingWebView(
                    title: "\(title) — \(selectedBrand.webViewTitle)",
                    url: selectedBrand.url
                )
            } else {
                ContentUnavailableView("No brands configured", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
