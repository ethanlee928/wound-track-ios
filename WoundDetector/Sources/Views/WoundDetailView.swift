import Charts
import SwiftData
import SwiftUI

struct WoundDetailView: View {
    @Bindable var wound: Wound
    @State private var showCapture = false

    private var sortedAssessments: [Assessment] {
        wound.assessments.sorted { $0.date < $1.date }
    }

    private var assessmentsWithArea: [Assessment] {
        sortedAssessments.filter { $0.areaCm2 != nil }
    }

    var body: some View {
        List {
            if !assessmentsWithArea.isEmpty {
                Section("Area Over Time") {
                    Chart(assessmentsWithArea) { assessment in
                        LineMark(
                            x: .value("Date", assessment.date),
                            y: .value("Area (cm²)", assessment.areaCm2 ?? 0)
                        )
                        .symbol(.circle)
                        PointMark(
                            x: .value("Date", assessment.date),
                            y: .value("Area (cm²)", assessment.areaCm2 ?? 0)
                        )
                    }
                    .frame(height: 200)
                }
            }

            Section("Assessments") {
                if sortedAssessments.isEmpty {
                    Text("No assessments yet. Tap the camera to capture one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedAssessments.reversed()) { assessment in
                        AssessmentRow(assessment: assessment)
                    }
                }
            }
        }
        .navigationTitle(wound.bodySite.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCapture = true } label: {
                    Label("Capture", systemImage: "camera.fill")
                }
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureFlowView(wound: wound) { showCapture = false }
        }
    }
}

private struct AssessmentRow: View {
    let assessment: Assessment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(assessment.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let area = assessment.areaCm2 {
                    Text(String(format: "%.2f cm²", area))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.blue)
                } else {
                    Text("Area N/A")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let stage = assessment.stageName {
                HStack(spacing: 6) {
                    Text(stage)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                    if let conf = assessment.stageConfidence {
                        Text(String(format: "%.0f%%", conf * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let thumb = assessmentThumbnail(for: assessment) {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
    }

    private func assessmentThumbnail(for assessment: Assessment) -> UIImage? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return UIImage(contentsOfFile: docs.appendingPathComponent(assessment.imageRelativePath).path)
    }
}
