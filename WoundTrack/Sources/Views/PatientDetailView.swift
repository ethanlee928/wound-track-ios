import SwiftData
import SwiftUI

struct PatientDetailView: View {
    @Bindable var patient: Patient
    @Environment(\.modelContext) private var modelContext
    @State private var showAddWound = false

    private func deleteWounds(at offsets: IndexSet, from sorted: [Wound]) {
        // Main-context delete keeps @Bindable patient.wounds in sync; see
        // WoundDetailView.deleteAssessments for the rationale.
        let targets = offsets.map { sorted[$0] }
        let files = targets.flatMap { wound in
            wound.assessments.flatMap {
                [$0.imageRelativePath, $0.maskRelativePath].compactMap { $0 }
            }
        }
        for wound in targets {
            modelContext.delete(wound)
        }
        try? modelContext.save()
        FileCleanup.removeRelative(paths: files)
    }

    var body: some View {
        List {
            Section("Patient Info") {
                LabeledContent("Name", value: patient.name)
                if let mrn = patient.mrn, !mrn.isEmpty {
                    LabeledContent("MRN", value: mrn)
                }
                LabeledContent("Since", value: patient.createdAt.formatted(date: .abbreviated, time: .omitted))
            }

            Section("Wounds") {
                if patient.wounds.isEmpty {
                    Text("No wounds yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    let sortedWounds = patient.wounds.sorted(by: { $0.firstSeen > $1.firstSeen })
                    ForEach(sortedWounds) { wound in
                        NavigationLink(value: wound) {
                            WoundRow(wound: wound)
                        }
                    }
                    .onDelete { offsets in
                        deleteWounds(at: offsets, from: sortedWounds)
                    }
                }
            }
        }
        .navigationTitle(patient.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddWound = true } label: {
                    Label("Add Wound", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: Wound.self) { wound in
            WoundDetailView(wound: wound)
        }
        .sheet(isPresented: $showAddWound) {
            AddWoundSheet(patient: patient)
        }
    }
}

private struct WoundRow: View {
    let wound: Wound

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(wound.bodySite.displayName)
                .font(.headline)
            HStack(spacing: 8) {
                Text("First seen \(wound.firstSeen.formatted(date: .abbreviated, time: .omitted))")
                Text("·")
                Text("\(wound.assessments.count) assessment\(wound.assessments.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AddWoundSheet: View {
    let patient: Patient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSite: BodySite = .sacrum

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tap the wound location on the body diagram.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    BodySitePicker(selection: $selectedSite)
                }
                .padding(.vertical)
            }
            .navigationTitle("New Wound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let container = modelContext.container
        let patientID = patient.persistentModelID
        let site = selectedSite
        Task {
            let store = WoundStore(modelContainer: container)
            _ = try? await store.createWound(patientID: patientID, bodySite: site)
            await MainActor.run { dismiss() }
        }
    }
}
