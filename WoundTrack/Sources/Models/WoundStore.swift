import Foundation
import SwiftData

/// Background actor that owns all SwiftData writes.
///
/// `ModelContext` is not `Sendable` and `@Model` instances cannot cross actor
/// boundaries safely. The pattern used throughout the app:
/// * UI reads via `@Query` on the main-actor `ModelContainer`.
/// * Writes (from background inference tasks or UI actions) hop to this actor,
///   which constructs and saves the models, then returns `PersistentIdentifier`s
///   the UI can refetch by id.
@ModelActor
actor WoundStore {
    func createPatient(name: String, mrn: String? = nil) throws -> PersistentIdentifier {
        let patient = Patient(name: name, mrn: mrn)
        modelContext.insert(patient)
        try modelContext.save()
        return patient.persistentModelID
    }

    func createWound(
        patientID: PersistentIdentifier,
        bodySite: BodySite
    ) throws -> PersistentIdentifier {
        guard let patient = self[patientID, as: Patient.self] else {
            throw WoundStoreError.patientNotFound
        }
        let wound = Wound(bodySite: bodySite, patient: patient)
        modelContext.insert(wound)
        try modelContext.save()
        return wound.persistentModelID
    }

    func createAssessment(
        woundID: PersistentIdentifier,
        imageRelativePath: String,
        maskRelativePath: String? = nil,
        areaCm2: Double? = nil,
        stageName: String? = nil,
        stageConfidence: Float? = nil,
        notesJSON: String? = nil
    ) throws -> PersistentIdentifier {
        guard let wound = self[woundID, as: Wound.self] else {
            throw WoundStoreError.woundNotFound
        }
        let assessment = Assessment(
            imageRelativePath: imageRelativePath,
            maskRelativePath: maskRelativePath,
            areaCm2: areaCm2,
            stageName: stageName,
            stageConfidence: stageConfidence,
            notesJSON: notesJSON,
            wound: wound
        )
        modelContext.insert(assessment)
        try modelContext.save()
        return assessment.persistentModelID
    }

    /// Deletes a patient and cascades to all wounds + assessments. Also removes
    /// the image/mask files on disk to keep storage reconciled with the DB.
    func deletePatient(_ id: PersistentIdentifier) throws {
        guard let patient = self[id, as: Patient.self] else { return }
        let filesToRemove = patient.wounds
            .flatMap { $0.assessments }
            .flatMap { [$0.imageRelativePath, $0.maskRelativePath].compactMap { $0 } }
        modelContext.delete(patient)
        try modelContext.save()
        removeFiles(relativePaths: filesToRemove)
    }

    /// Deletes a wound and cascades to its assessments (+ their image files).
    func deleteWound(_ id: PersistentIdentifier) throws {
        guard let wound = self[id, as: Wound.self] else { return }
        let filesToRemove = wound.assessments
            .flatMap { [$0.imageRelativePath, $0.maskRelativePath].compactMap { $0 } }
        modelContext.delete(wound)
        try modelContext.save()
        removeFiles(relativePaths: filesToRemove)
    }

    /// Deletes a single assessment (+ its image files).
    func deleteAssessment(_ id: PersistentIdentifier) throws {
        guard let assessment = self[id, as: Assessment.self] else { return }
        let filesToRemove = [assessment.imageRelativePath, assessment.maskRelativePath]
            .compactMap { $0 }
        modelContext.delete(assessment)
        try modelContext.save()
        removeFiles(relativePaths: filesToRemove)
    }

    private func removeFiles(relativePaths: [String]) {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        for rel in relativePaths {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(rel))
        }
    }
}

enum WoundStoreError: LocalizedError {
    case patientNotFound
    case woundNotFound

    var errorDescription: String? {
        switch self {
        case .patientNotFound: return "Patient not found."
        case .woundNotFound: return "Wound not found."
        }
    }
}
