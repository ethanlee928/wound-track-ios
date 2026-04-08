import SwiftUI

/// Two-row picker for selecting model task (General / Wound) and size (N / S / M).
/// Sizes that don't exist for the selected task are disabled.
struct ModelPickerView: View {
    @ObservedObject var viewModel: DetectionViewModel

    private var currentTask: ModelVariant.Task { viewModel.currentVariant.task }
    private var currentSize: ModelVariant.Size { viewModel.currentVariant.size }

    /// Sizes that have a bundled model for the currently selected task.
    private var availableSizes: [ModelVariant.Size] {
        ModelVariant.variants(for: currentTask).map(\.size)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Model")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if viewModel.isModelLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading \(viewModel.currentVariant.displayName)…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("\(viewModel.currentVariant.displayName) · \(viewModel.currentVariant.approxSize)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Task selector: General (COCO) vs Wound (FUSeg)
            Picker("Task", selection: Binding(
                get: { currentTask },
                set: { newTask in
                    // Try to keep the same size; fall back to nano if missing
                    let target = ModelVariant.variant(task: newTask, size: currentSize)
                        ?? ModelVariant.variant(task: newTask, size: .nano)
                    if let target = target {
                        viewModel.switchModel(to: target)
                    }
                }
            )) {
                ForEach(ModelVariant.Task.allCases) { task in
                    Text(task.displayName).tag(task)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isModelLoading)

            // Size selector — only sizes that exist for the current task
            Picker("Size", selection: Binding(
                get: { currentSize },
                set: { newSize in
                    if let target = ModelVariant.variant(task: currentTask, size: newSize) {
                        viewModel.switchModel(to: target)
                    }
                }
            )) {
                ForEach(availableSizes) { size in
                    Text(size.shortLabel).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isModelLoading)
        }
    }
}
