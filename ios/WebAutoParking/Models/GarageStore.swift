import Foundation
import Combine

@MainActor
final class GarageStore: ObservableObject {
    @Published private(set) var garages: [Garage] = []

    private let defaultsKey = "savedGarages.v2"
    private let legacyDefaultsKey = "savedGarages"

    init() {
        load()
    }

    func add(_ garage: Garage) {
        let normalized = Garage(
            facilityID: garage.facilityID.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: garage.provider,
            name: garage.name.trimmingCharacters(in: .whitespacesAndNewlines),
            address: garage.address.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: garage.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !normalized.facilityID.isEmpty else { return }

        if let index = garages.firstIndex(where: {
            $0.facilityID == normalized.facilityID && $0.provider == normalized.provider
        }) {
            garages[index] = normalized
        } else {
            garages.insert(normalized, at: 0)
        }
        save()
    }

    func remove(at offsets: IndexSet) {
        garages.remove(atOffsets: offsets)
        save()
    }

    func remove(_ garage: Garage) {
        garages.removeAll {
            $0.facilityID == garage.facilityID && $0.provider == garage.provider
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Garage].self, from: data),
           !decoded.isEmpty {
            garages = ensureDefaults(in: decoded)
            save()
            return
        }

        if let data = UserDefaults.standard.data(forKey: legacyDefaultsKey),
           let decoded = try? JSONDecoder().decode([Garage].self, from: data),
           !decoded.isEmpty {
            garages = ensureDefaults(in: decoded)
            save()
            return
        }

        garages = Self.defaultGarages
        save()
    }

    private func ensureDefaults(in existing: [Garage]) -> [Garage] {
        var result = existing
        // Drop retired presets (e.g. Lincoln Harbor) from persisted lists.
        result.removeAll { Self.isRetiredPreset($0) }
        for preset in Self.defaultGarages {
            let has = result.contains {
                $0.facilityID == preset.facilityID && $0.provider == preset.provider
            }
            if !has {
                result.append(preset)
            }
        }
        // Keep default order from `defaultGarages` (ParkChirp Harbor last).
        return Self.orderedWithDefaultsFirst(result)
    }

    private static func isRetiredPreset(_ garage: Garage) -> Bool {
        garage.provider == .fixedDuration && garage.facilityID == "12551" // Lincoln Harbor Garage
    }

    /// Stable list: presets in `defaultGarages` order, then any custom garages.
    private static func orderedWithDefaultsFirst(_ garages: [Garage]) -> [Garage] {
        var remaining = garages
        var ordered: [Garage] = []
        for preset in defaultGarages {
            if let idx = remaining.firstIndex(where: {
                $0.facilityID == preset.facilityID && $0.provider == preset.provider
            }) {
                ordered.append(remaining.remove(at: idx))
            }
        }
        ordered.append(contentsOf: remaining)
        return ordered
    }

    private static let defaultGarages: [Garage] = [
        .bisbyJerseyCity,
        .harborWeehawken,
        .mallDriveJerseyCity,
        .harborParkChirp
    ]

    private func save() {
        guard let data = try? JSONEncoder().encode(garages) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
