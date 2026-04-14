import SwiftUI

/// Single source of truth for wound stage classification.
/// Maps model class labels → display info, NPIAP descriptions, and mask colors.
enum WoundStage: String, CaseIterable, Identifiable {
    case stage1 = "stage1"
    case stage2 = "stage2"
    case stage3 = "stage3"
    case stage4 = "stage4"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stage1: return "Stage 1"
        case .stage2: return "Stage 2"
        case .stage3: return "Stage 3"
        case .stage4: return "Stage 4"
        }
    }

    var npiapDescription: String {
        switch self {
        case .stage1: return "Non-blanchable erythema of intact skin"
        case .stage2: return "Partial-thickness skin loss with exposed dermis"
        case .stage3: return "Full-thickness skin loss"
        case .stage4: return "Full-thickness skin and tissue loss"
        }
    }

    var maskColor: Color {
        switch self {
        case .stage1: return .yellow
        case .stage2: return .orange
        case .stage3: return .red
        case .stage4: return Color(red: 0.55, green: 0.0, blue: 0.0)
        }
    }

    /// Try to match a model class label string to a WoundStage.
    /// Handles variations like "stage1", "Stage 1", "Stage-1", "stage_1".
    static func from(classLabel: String) -> WoundStage? {
        let normalized = classLabel
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return WoundStage.allCases.first { $0.rawValue == normalized }
    }
}
