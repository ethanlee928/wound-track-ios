import Foundation
import SwiftData

@Model
final class Patient {
    @Attribute(.unique) var id: UUID
    var name: String
    var mrn: String?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Wound.patient)
    var wounds: [Wound] = []

    init(id: UUID = UUID(), name: String, mrn: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.mrn = mrn
        self.createdAt = createdAt
    }
}
