import Foundation

/// Anatomical body site a wound is located at. Raw values are stable strings so
/// enum reordering never breaks on-disk SwiftData rows.
enum BodySite: String, Codable, CaseIterable, Identifiable {
    case sacrum
    case leftHeel = "left_heel"
    case rightHeel = "right_heel"
    case leftTrochanter = "left_trochanter"
    case rightTrochanter = "right_trochanter"
    case leftIschium = "left_ischium"
    case rightIschium = "right_ischium"
    case leftFirstMT = "left_first_mt"
    case rightFirstMT = "right_first_mt"
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sacrum: return "Sacrum"
        case .leftHeel: return "Left Heel"
        case .rightHeel: return "Right Heel"
        case .leftTrochanter: return "Left Trochanter"
        case .rightTrochanter: return "Right Trochanter"
        case .leftIschium: return "Left Ischium"
        case .rightIschium: return "Right Ischium"
        case .leftFirstMT: return "Left 1st MT Head"
        case .rightFirstMT: return "Right 1st MT Head"
        case .other: return "Other"
        }
    }
}
