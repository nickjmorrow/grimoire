import Foundation

/// The four phases of the day the app icon follows. Night is the primary icon; the others are swapped in while the app runs.
/// Boundaries are fixed local hours rather than real sunrise and sunset, so the icon needs no location access.
public enum TimeOfDay: CaseIterable, Sendable {
    case dawn, day, dusk, night

    /// The local hour each phase begins.
    public var startHour: Int {
        switch self {
        case .dawn: 5
        case .day: 9
        case .dusk: 17
        case .night: 21
        }
    }

    public static func at(_ date: Date, calendar: Calendar = .current) -> TimeOfDay {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<9: return .dawn
        case 9..<17: return .day
        case 17..<21: return .dusk
        default: return .night
        }
    }

    /// The next moment the phase changes, so a running app can sleep until then.
    public static func nextChange(after date: Date, calendar: Calendar = .current) -> Date {
        let hours = allCases.map(\.startHour).sorted()
        let candidates = hours.compactMap { calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0, second: 0), matchingPolicy: .nextTime) }
        return candidates.min() ?? date.addingTimeInterval(3600)
    }

    /// iOS alternate icon name (nil is the primary icon, night).
    public var iOSIconName: String? {
        switch self {
        case .dawn: "AppIconDawn"
        case .day: "AppIconDay"
        case .dusk: "AppIconDusk"
        case .night: nil
        }
    }

    /// Name of the Mac asset-catalog image for this phase.
    public var macImageName: String {
        switch self {
        case .dawn: "IconDawn"
        case .day: "IconDay"
        case .dusk: "IconDusk"
        case .night: "IconNight"
        }
    }
}
