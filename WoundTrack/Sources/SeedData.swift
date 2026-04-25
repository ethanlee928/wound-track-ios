import Foundation
import SwiftData
import UIKit

/// Populates the app with demo patients, wounds, and assessments on first
/// launch. Idempotent: if any patients already exist, seeding is skipped.
///
/// Used for the MSc demo so the presenter opens the app to a pre-populated
/// healing trajectory. In a real build we'd gate this behind a flag — for the
/// demo, this is desirable default behaviour.
enum SeedData {

    /// Seeds two demo patients with simulated healing trajectories if the
    /// store is empty. Safe to call on every cold launch.
    @MainActor
    static func seedIfNeeded(container: ModelContainer) async {
        let ctx = ModelContext(container)
        guard let count = try? ctx.fetchCount(FetchDescriptor<Patient>()), count == 0 else {
            return
        }
        let store = WoundStore(modelContainer: container)

        // Patient 1: healing. Area goes 12 → 9.5 → 7.2 → 5.1 cm² over 4 weeks.
        if let p1 = try? await store.createPatient(name: "Demo · Mrs. Chan", mrn: "DEMO-001") {
            if let w1 = try? await store.createWound(patientID: p1, bodySite: .sacrum) {
                await seedAssessments(
                    store: store,
                    woundID: w1,
                    trajectory: [(weeksAgo: 4, area: 12.0, stage: "stage3"),
                                 (weeksAgo: 3, area: 9.5, stage: "stage3"),
                                 (weeksAgo: 2, area: 7.2, stage: "stage2"),
                                 (weeksAgo: 1, area: 5.1, stage: "stage2")]
                )
            }
            if let w2 = try? await store.createWound(patientID: p1, bodySite: .leftHeel) {
                await seedAssessments(
                    store: store,
                    woundID: w2,
                    trajectory: [(weeksAgo: 3, area: 3.4, stage: "stage2"),
                                 (weeksAgo: 2, area: 2.8, stage: "stage2"),
                                 (weeksAgo: 1, area: 2.1, stage: "stage1")]
                )
            }
        }

        // Patient 2: stalled. Area oscillates, no clear healing signal.
        if let p2 = try? await store.createPatient(name: "Demo · Mr. Wong", mrn: "DEMO-002") {
            if let w = try? await store.createWound(patientID: p2, bodySite: .rightHeel) {
                await seedAssessments(
                    store: store,
                    woundID: w,
                    trajectory: [(weeksAgo: 4, area: 4.2, stage: "stage2"),
                                 (weeksAgo: 3, area: 4.5, stage: "stage2"),
                                 (weeksAgo: 2, area: 4.1, stage: "stage2"),
                                 (weeksAgo: 1, area: 4.4, stage: "stage2")]
                )
            }
        }
    }

    private static func seedAssessments(
        store: WoundStore,
        woundID: PersistentIdentifier,
        trajectory: [(weeksAgo: Int, area: Double, stage: String)]
    ) async {
        for entry in trajectory {
            _ = try? await store.createAssessment(
                woundID: woundID,
                imageRelativePath: "seed/placeholder.jpg",
                maskRelativePath: nil,
                areaCm2: entry.area,
                stageName: entry.stage,
                stageConfidence: 0.8,
                notesJSON: nil
            )
            // Overwrite the auto-now date with a weeks-ago timestamp via a
            // second context. SwiftData doesn't let us set this through the
            // actor since createAssessment already saved.
            let ctx = ModelContext(store.modelContainer)
            if let a = (try? ctx.fetch(FetchDescriptor<Assessment>()))?.last {
                a.date = Calendar.current.date(byAdding: .weekOfYear, value: -entry.weeksAgo, to: .now) ?? .now
                try? ctx.save()
            }
        }
    }
}
