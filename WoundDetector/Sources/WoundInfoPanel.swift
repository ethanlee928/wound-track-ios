import SwiftUI

struct WoundInfoPanel: View {
    let detections: [DetectionResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detection Results")
                .font(.headline)

            ForEach(detections) { detection in
                DetectionRow(detection: detection)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct DetectionRow: View {
    let detection: DetectionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let stage = detection.woundStage {
                    Circle()
                        .fill(stage.maskColor)
                        .frame(width: 12, height: 12)
                    Text(stage.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text(detection.className)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Spacer()

                Text(String(format: "%.1f%%", detection.confidence * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let stage = detection.woundStage {
                Text(stage.npiapDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
