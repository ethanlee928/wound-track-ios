import Foundation

/// A bundled YOLO26-seg model variant.
/// Each variant combines a *task* (general COCO vs wound-specific) with a *size* (n / s / m).
enum ModelVariant: String, CaseIterable, Identifiable {
    // General-purpose COCO segmentation (80 classes, pretrained, no fine-tuning)
    case cocoNano = "yolo26n-seg"
    case cocoSmall = "yolo26s-seg"
    case cocoMedium = "yolo26m-seg"

    // Wound-specific (single class), fine-tuned on the AZH/FUSeg foot ulcer dataset
    case woundNano = "wound-yolo26n-seg"
    case woundSmall = "wound-yolo26s-seg"

    var id: String { rawValue }

    enum Task: String, CaseIterable, Identifiable {
        case general
        case wound

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .general: return "General"
            case .wound: return "Wound"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "COCO 80-class"
            case .wound: return "FUSeg foot ulcer"
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable {
        case nano
        case small
        case medium

        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .nano: return "N"
            case .small: return "S"
            case .medium: return "M"
            }
        }
        var displayName: String {
            switch self {
            case .nano: return "Nano"
            case .small: return "Small"
            case .medium: return "Medium"
            }
        }
    }

    var task: Task {
        switch self {
        case .cocoNano, .cocoSmall, .cocoMedium: return .general
        case .woundNano, .woundSmall: return .wound
        }
    }

    var size: Size {
        switch self {
        case .cocoNano, .woundNano: return .nano
        case .cocoSmall, .woundSmall: return .small
        case .cocoMedium: return .medium
        }
    }

    /// Approximate compiled `.mlmodelc` size, for the picker subtitle.
    var approxSize: String {
        switch size {
        case .nano: return "~5 MB"
        case .small: return "~20 MB"
        case .medium: return "~50 MB"
        }
    }

    /// Full display name for detail views, e.g. "General · Nano".
    var displayName: String { "\(task.displayName) · \(size.displayName)" }

    /// All variants available for a given task.
    static func variants(for task: Task) -> [ModelVariant] {
        ModelVariant.allCases.filter { $0.task == task }
    }

    /// Find a variant by task + size, returning nil if it doesn't exist
    /// (e.g. there is no wound · Medium).
    static func variant(task: Task, size: Size) -> ModelVariant? {
        ModelVariant.allCases.first { $0.task == task && $0.size == size }
    }

    /// Name of the paired SGIE stage classifier model, if any.
    /// Always uses the nano cls variant (3 MB, <10ms on Neural Engine) —
    /// the cls model is so cheap that matching seg size adds no benefit.
    /// Returns nil for COCO models (no staging).
    var stageClassifierName: String? {
        switch self {
        // PLACEHOLDER: swap for DFUC 2021 classifier when available
        case .woundNano, .woundSmall: return "wound-stage-yolo26n-cls"
        default: return nil
        }
    }
}
