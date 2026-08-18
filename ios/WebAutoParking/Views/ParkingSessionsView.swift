import SwiftUI
import UIKit

/// Last 3 attempted Zone checkouts and last 7 paid guest receipts.
struct ParkingSessionsView: View {
    @ObservedObject private var receipts = ParkingSessionStore.shared
    @ObservedObject private var attempts = AttemptedZoneStore.shared
    @State private var selectedReceipt: SavedParkingSession?
    @State private var selectedAttempt: AttemptedZone?
    @State private var pasteFailed = false

    private var isEmpty: Bool {
        attempts.attempts.isEmpty && receipts.sessions.isEmpty
    }

    private var zonePrefill: PrefillContext {
        PrefillContext(
            mode: .parkMobileZone,
            maxDurationMinutes: SessionPreferences.shared.zoneMaxDurationMinutes,
            zoneAutomationEnabled: true
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty {
                    ContentUnavailableView(
                        "No zone history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Attempted Zone checkouts (last 3) and paid street-zone guest receipts (last 7) show here. Garage reservations are not stored.")
                    )
                } else {
                    List {
                        if !attempts.attempts.isEmpty {
                            Section("Attempted") {
                                ForEach(attempts.attempts) { attempt in
                                    Button {
                                        selectedAttempt = attempt
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(attempt.title)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text(attempt.subtitle)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            attempts.remove(id: attempt.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        if !receipts.sessions.isEmpty {
                            Section("Receipts") {
                                ForEach(receipts.sessions) { session in
                                    Button {
                                        selectedReceipt = session
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
                                            receipts.remove(id: session.id)
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
                }
            }
            .navigationTitle("Z. History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        pasteFailed = !receipts.addFromClipboard()
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
            .navigationDestination(item: $selectedAttempt) { attempt in
                ParkingWebView(
                    title: attempt.title,
                    url: attempt.startURL,
                    prefillContext: zonePrefill
                )
            }
            .navigationDestination(item: $selectedReceipt) { session in
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
