import SwiftUI

struct AddGarageView: View {
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ParkingProvider = .fixedDuration
    @State private var facilityID = ""
    @State private var name = ""
    @State private var address = ""
    @State private var notes = ""

    private var canSave: Bool {
        !facilityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(ParkingProvider.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                TextField(provider.idLabel, text: $facilityID)
                    .keyboardType(provider == .parkChirp ? .default : .numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Name", text: $name)
                TextField("Address", text: $address, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Garage")
            } footer: {
                Text(provider.idHelp)
            }

            Section("Presets") {
                Button("1525 Harbor Garage") {
                    apply(Garage.harborWeehawken)
                }
                Button("1525 Harbor (ParkChirp)") {
                    apply(Garage.harborParkChirp)
                }
                Button("The Bisby Garage") {
                    apply(Garage.bisbyJerseyCity)
                }
                Button("29245 Mall Dr. E") {
                    apply(Garage.mallDriveJerseyCity)
                }
            }
        }
        .navigationTitle("Add Garage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.add(
                        Garage(
                            facilityID: facilityID,
                            provider: provider,
                            name: name.isEmpty ? "Garage \(facilityID)" : name,
                            address: address,
                            notes: notes
                        )
                    )
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }

    private func apply(_ garage: Garage) {
        provider = garage.provider
        facilityID = garage.facilityID
        name = garage.name
        address = garage.address
        notes = garage.notes
    }
}

#Preview {
    NavigationStack {
        AddGarageView()
    }
    .environmentObject(GarageStore())
}
