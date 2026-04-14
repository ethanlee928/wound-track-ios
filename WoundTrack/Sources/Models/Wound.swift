import Foundation
import SwiftData

@Model
final class Wound {
    @Attribute(.unique) var id: UUID
    /// Stored as raw String so BodySite enum reordering never corrupts rows.
    var bodySiteRaw: String
    var firstSeen: Date
    var patient: Patient?

    @Relationship(deleteRule: .cascade, inverse: \Assessment.wound)
    var assessments: [Assessment] = []

    var bodySite: BodySite {
        get { BodySite(rawValue: bodySiteRaw) ?? .other }
        set { bodySiteRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), bodySite: BodySite, firstSeen: Date = .now, patient: Patient? = nil) {
        self.id = id
        self.bodySiteRaw = bodySite.rawValue
        self.firstSeen = firstSeen
        self.patient = patient
    }
}
