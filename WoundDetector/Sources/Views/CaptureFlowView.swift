import SwiftData
import SwiftUI
import UIKit

/// End-to-end capture flow: ARCaptureView → inference → area calc → review → save.
///
/// Holds a private `DetectionViewModel` so inference state doesn't leak into
/// the longitudinal UI (it has its own flow). Model loads lazily when the
/// capture view first appears.
struct CaptureFlowView: View {
    let wound: Wound
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var detector = DetectionViewModel()

    @State private var phase: Phase = .capturing
    @State private var errorMessage: String?

    enum Phase {
        case capturing
        case processing
        case review(ReviewData)
    }

    struct ReviewData {
        let capturedImage: UIImage
        let annotatedImage: UIImage
        let areaCm2: Double?
        let tiltDegrees: Double?
        let stageName: String?
        let stageConfidence: Float?
        let inference: CaptureInferenceResult
        let capturedFrame: ARCapturedFrame
    }

    var body: some View {
        Group {
            switch phase {
            case .capturing:
                ARCaptureView(
                    onCapture: handleCapture,
                    onDismiss: onClose
                )
            case .processing:
                ProcessingView()
            case .review(let data):
                ReviewView(
                    wound: wound,
                    data: data,
                    onRetake: { phase = .capturing },
                    onSaved: onClose
                )
            }
        }
        .alert("Capture Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func handleCapture(_ frame: ARCapturedFrame) {
        phase = .processing
        Task {
            guard let inference = await detector.inferForCapture(image: frame.image) else {
                await MainActor.run {
                    errorMessage = "No wound detected in the captured image."
                    phase = .capturing
                }
                return
            }
            let areaResult = computeArea(frame: frame, inference: inference)
            let review = ReviewData(
                capturedImage: frame.image,
                annotatedImage: inference.annotatedImage ?? frame.image,
                areaCm2: areaResult?.areaCm2,
                tiltDegrees: areaResult.map { $0.tiltAngleRadians * 180 / .pi },
                stageName: inference.stageName,
                stageConfidence: inference.stageConfidence,
                inference: inference,
                capturedFrame: frame
            )
            await MainActor.run { phase = .review(review) }
        }
    }

    private func computeArea(
        frame: ARCapturedFrame,
        inference: CaptureInferenceResult
    ) -> AreaCalculator.Result? {
        guard let maskCG = inference.combinedMask else { return nil }
        // YOLO's combinedMask is at model input size (~640×640). Rasterize into
        // capture resolution so the mask's pixel coordinates match the bbox
        // and the depth-sampling math in AreaCalculator.
        guard var mask = BooleanMask.from(cgImage: maskCG, targetSize: frame.imageSize) else {
            return nil
        }
        // Intersect to the primary detection's bbox so we don't accumulate
        // neighbouring instances' pixels.
        mask = mask.intersected(with: inference.firstBox)
        return AreaCalculator.measure(
            mask: mask,
            depthMap: frame.depthMap,
            confidenceMap: frame.confidenceMap,
            intrinsics: frame.intrinsics,
            captureSize: frame.imageSize
        )
    }
}

// MARK: - Processing

private struct ProcessingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("Analyzing wound…")
                    .foregroundStyle(.white)
                    .font(.headline)
            }
        }
    }
}

// MARK: - Review

private struct ReviewView: View {
    let wound: Wound
    let data: CaptureFlowView.ReviewData
    let onRetake: () -> Void
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var notes: String = ""
    @State private var pain: Int = 0
    @State private var exudate: Exudate = .none
    @State private var dressing: String = ""
    @State private var isSaving = false
    @State private var saveError: String?

    enum Exudate: String, CaseIterable, Identifiable {
        case none, scant, moderate, heavy
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Rotate for display so it reads upright (intrinsics live
                    // in the native landscape frame; rotation here is cosmetic).
                    Image(uiImage: data.annotatedImage.rotated90())
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)

                    MeasurementCard(data: data)

                    NotesForm(
                        notes: $notes,
                        pain: $pain,
                        exudate: $exudate,
                        dressing: $dressing
                    )
                }
                .padding()
            }
            .navigationTitle("Review Assessment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake", action: onRetake)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: save)
                        .disabled(isSaving)
                }
            }
            .alert("Save failed", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        isSaving = true
        // File I/O and DB write are both cheap enough that doing them on the
        // main actor (blocking UI for ~tens of ms) is fine and keeps us on
        // the *same* ModelContext that the parent WoundDetailView observes.
        // Going through WoundStore's @ModelActor here caused a cross-context
        // merge lag that hid the new Assessment from @Bindable wound.
        //
        // Save the upright (rotated) versions so thumbnails in the timeline
        // read correctly. We don't need the landscape-native frame after
        // AreaCalculator has already produced cm² — the image on disk is for
        // display only.
        guard let paths = writeImageFiles(
            captured: data.capturedImage.rotated90(),
            annotated: data.annotatedImage.rotated90()
        ) else {
            saveError = "Couldn't write the captured image to storage. Please try again."
            isSaving = false
            return
        }
        let notesPayload = NotesPayload(
            notes: notes,
            pain: pain,
            exudate: exudate.rawValue,
            dressing: dressing
        )
        let assessment = Assessment(
            imageRelativePath: paths.imageRel,
            maskRelativePath: paths.maskRel,
            areaCm2: data.areaCm2,
            stageName: data.stageName,
            stageConfidence: data.stageConfidence,
            notesJSON: notesPayload.jsonString,
            wound: wound
        )
        modelContext.insert(assessment)
        do {
            try modelContext.save()
            onSaved()
        } catch {
            print("Save failed: \(error)")
            saveError = "Saving the assessment failed: \(error.localizedDescription)"
            isSaving = false
        }
    }

    /// Writes the captured RGB and annotated overlay to Documents/assessments/.
    /// Returns relative paths for DB persistence.
    private func writeImageFiles(
        captured: UIImage,
        annotated: UIImage
    ) -> (imageRel: String, maskRel: String?)? {
        guard
            let docs = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
        else { return nil }
        let dir = docs.appendingPathComponent("assessments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let imgName = "capture-\(stamp).jpg"
        let annoName = "annotated-\(stamp).jpg"
        guard
            let imgData = captured.jpegData(compressionQuality: 0.9),
            let annoData = annotated.jpegData(compressionQuality: 0.9)
        else { return nil }
        do {
            try imgData.write(to: dir.appendingPathComponent(imgName))
            try annoData.write(to: dir.appendingPathComponent(annoName))
        } catch {
            return nil
        }
        return ("assessments/\(imgName)", "assessments/\(annoName)")
    }
}

// MARK: - Review subviews

private struct MeasurementCard: View {
    let data: CaptureFlowView.ReviewData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Measurement", systemImage: "ruler")
                    .font(.headline)
                Spacer()
            }
            if let area = data.areaCm2 {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.2f", area))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("cm²")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if let tilt = data.tiltDegrees {
                    Text(String(format: "Capture tilt: %.0f°", tilt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Area not available (no valid depth samples)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let stage = data.stageName {
                HStack {
                    Text("Stage: \(stage)")
                        .font(.subheadline)
                    if let conf = data.stageConfidence {
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
}

private struct NotesForm: View {
    @Binding var notes: String
    @Binding var pain: Int
    @Binding var exudate: ReviewView.Exudate
    @Binding var dressing: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notes")
                .font(.headline)

            HStack {
                Text("Pain (0–10)")
                Spacer()
                Stepper("\(pain)", value: $pain, in: 0...10)
                    .labelsHidden()
                Text("\(pain)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 28)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Exudate")
                Picker("Exudate", selection: $exudate) {
                    ForEach(ReviewView.Exudate.allCases) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Dressing")
                TextField("e.g. foam, alginate", text: $dressing)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Free-text notes")
                TextEditor(text: $notes)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(12)
    }
}

// MARK: - Persistence payload

private struct NotesPayload: Codable {
    let notes: String
    let pain: Int
    let exudate: String
    let dressing: String

    var jsonString: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - UIImage rotate helper

private extension UIImage {
    /// Rotate a CGImage-backed UIImage 90° clockwise so the landscape-native
    /// capture reads upright in portrait UI.
    func rotated90() -> UIImage {
        guard let cg = cgImage else { return self }
        let newSize = CGSize(width: size.height, height: size.width)
        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        guard let ctx = UIGraphicsGetCurrentContext() else { return self }
        ctx.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        ctx.rotate(by: .pi / 2)
        ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
}
