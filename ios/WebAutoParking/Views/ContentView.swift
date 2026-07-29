import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            GarageListView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GarageStore())
}
