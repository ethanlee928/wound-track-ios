import Foundation
import SwiftData

@Model
final class Assessment {
    @Attribute(.unique) var id: UUID
    var date: Date
    /// Relative to the app's Documents directory. Written before the row is saved.
    var imageRelativePath: String
    var maskRelativePath: String?
    /// nil when live capture was unavailable (e.g. imported from photo library).
    var areaCm2: Double?
    var stageName: String?
    var stageConfidence: Float?
    /// Structured fields serialized as JSON: exudate, pain, dressing, freeText.
    var notesJSON: String?
    var wound: Wound?

    init(
        id: UUID = UUID(),
        date: Date = .now,
        imageRelativePath: String,
        maskRelativePath: String? = nil,
        areaCm2: Double? = nil,
        stageName: String? = nil,
        stageConfidence: Float? = nil,
        notesJSON: String? = nil,
        wound: Wound? = nil
    ) {
        self.id = id
        self.date = date
        self.imageRelativePath = imageRelativePath
        self.maskRelativePath = maskRelativePath
        self.areaCm2 = areaCm2
        self.stageName = stageName
        self.stageConfidence = stageConfidence
        self.notesJSON = notesJSON
        self.wound = wound
    }
}
