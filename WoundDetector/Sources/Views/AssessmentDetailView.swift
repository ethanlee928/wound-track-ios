import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Full-screen assessment detail: captured image, measurement card, stage,
/// and structured notes. Reached by tapping a row in the wound timeline.
struct AssessmentDetailView: View {
    @Bindable var assessment: Assessment

    private var notes: DecodedNotes {
        guard let json = assessment.notesJSON,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DecodedNotes.self, from: data)
        else {
            return DecodedNotes(notes: "", pain: 0, exudate: "", dressing: "")
        }
        return decoded
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = loadImage(relativePath: assessment.imageRelativePath) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                }

                measurementCard

                if !notes.notes.isEmpty || notes.pain > 0 || !notes.exudate.isEmpty || !notes.dressing.isEmpty {
                    notesCard
                }
            }
            .padding()
        }
        .navigationTitle(assessment.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Measurement", systemImage: "ruler").font(.headline)
            if let area = assessment.areaCm2 {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.2f", area))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                    Text("cm²").font(.title3).foregroundStyle(.secondary)
                }
            } else {
                Text("Area not available")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let stage = assessment.stageName {
                HStack(spacing: 6) {
                    Text("Stage: \(stage)").font(.subheadline)
                    if let conf = assessment.stageConfidence {
                        Text(String(format: "(%.0f%%)", conf * 100))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes", systemImage: "note.text").font(.headline)
            if notes.pain > 0 {
                LabeledContent("Pain", value: "\(notes.pain) / 10")
            }
            if !notes.exudate.isEmpty {
                LabeledContent("Exudate", value: notes.exudate.capitalized)
            }
            if !notes.dressing.isEmpty {
                LabeledContent("Dressing", value: notes.dressing)
            }
            if !notes.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free-text").font(.caption).foregroundStyle(.secondary)
                    Text(notes.notes).font(.body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(12)
    }

    private func loadImage(relativePath: String) -> UIImage? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return UIImage(contentsOfFile: docs.appendingPathComponent(relativePath).path)
    }
}

private struct DecodedNotes: Codable {
    let notes: String
    let pain: Int
    let exudate: String
    let dressing: String
}
