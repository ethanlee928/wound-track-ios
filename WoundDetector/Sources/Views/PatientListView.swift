import SwiftData
import SwiftUI

struct PatientListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.name) private var patients: [Patient]
    @State private var showAddPatient = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(patients) { patient in
                    NavigationLink(value: patient) {
                        PatientRow(patient: patient)
                    }
                }
                .onDelete(perform: deletePatients)
            }
            .overlay {
                if patients.isEmpty {
                    ContentUnavailableView(
                        "No Patients",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Tap + to add a patient to start tracking wounds.")
                    )
                }
            }
            .navigationTitle("Patients")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddPatient = true } label: {
                        Label("Add Patient", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Patient.self) { patient in
                PatientDetailView(patient: patient)
            }
            .sheet(isPresented: $showAddPatient) {
                AddPatientSheet()
            }
        }
    }

    private func deletePatients(at offsets: IndexSet) {
        let container = modelContext.container
        let ids = offsets.map { patients[$0].persistentModelID }
        Task {
            let store = WoundStore(modelContainer: container)
            for id in ids {
                try? await store.deletePatient(id)
            }
        }
    }
}

private struct PatientRow: View {
    let patient: Patient

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(patient.name)
                .font(.headline)
            HStack(spacing: 8) {
                if let mrn = patient.mrn, !mrn.isEmpty {
                    Text("MRN: \(mrn)")
                }
                Text("\(patient.wounds.count) wound\(patient.wounds.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct AddPatientSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var mrn = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Patient") {
                    TextField("Full name", text: $name)
                    TextField("MRN (optional)", text: $mrn)
                }
            }
            .navigationTitle("New Patient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedMRN = mrn.trimmingCharacters(in: .whitespaces)
        let container = modelContext.container
        Task {
            let store = WoundStore(modelContainer: container)
            _ = try? await store.createPatient(
                name: trimmedName,
                mrn: trimmedMRN.isEmpty ? nil : trimmedMRN
            )
            await MainActor.run { dismiss() }
        }
    }
}
