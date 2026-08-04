import AppIntents

/// Shared with the widget extension so Control Center can open the host app.
enum OpenParkingTarget: String, AppEnum {
    case home

    static var typeDisplayRepresentation = TypeDisplayRepresentation("Parking")
    static var caseDisplayRepresentations: [OpenParkingTarget: DisplayRepresentation] = [
        .home: DisplayRepresentation(title: "Parking")
    ]
}

struct OpenParkingIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Parking"

    @Parameter(title: "Target")
    var target: OpenParkingTarget

    init() {
        self.target = .home
    }

    init(target: OpenParkingTarget) {
        self.target = target
    }
}
