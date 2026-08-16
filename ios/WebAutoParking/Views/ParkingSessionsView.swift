import SwiftUI

/// Last 10 captured Zone (on-street) guest receipt links. Garage reservations are not stored here.
struct ParkingSessionsView: View {
    @ObservedObject private var store = ParkingSessionStore.shared
    @State private var selected: SavedParkingSession?
    @State private var pasteFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "No saved zone receipts",
                        systemImage: "receipt",
                        description: Text("Street-zone guest receipts live here (not garage reservations). After payment, copy the timer-page link and Paste link here if it was not saved automatically.")
                    )
                } else {
                    List {
                        ForEach(store.sessions) { session in
                            Button {
                                selected = session
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(session.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(session.urlString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.remove(id: session.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    UIPasteboard.general.string = session.urlString
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = session.urlString
                                } label: {
                                    Label("Copy link", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: session.urlString) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Z. Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        pasteFailed = !store.addFromClipboard()
                    } label: {
                        Label("Paste link", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .alert("No zone receipt link on the clipboard", isPresented: $pasteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("On the Zone timer page after payment, tap Copy link, then Paste link here.")
            }
            .navigationDestination(item: $selected) { session in
                if let url = session.url {
                    ParkingWebView(title: session.title, url: url)
                } else {
                    Text("Invalid session URL")
                }
            }
        }
    }
}

#Preview {
    ParkingSessionsView()
}
