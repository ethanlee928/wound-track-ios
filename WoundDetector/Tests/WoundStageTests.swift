import XCTest
@testable import WoundDetector

final class WoundStageTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(WoundStage.stage1.displayName, "Stage 1")
        XCTAssertEqual(WoundStage.stage2.displayName, "Stage 2")
        XCTAssertEqual(WoundStage.stage3.displayName, "Stage 3")
        XCTAssertEqual(WoundStage.stage4.displayName, "Stage 4")
    }

    func testNPIAPDescriptions() {
        XCTAssertEqual(WoundStage.stage1.npiapDescription, "Non-blanchable erythema of intact skin")
        XCTAssertEqual(WoundStage.stage2.npiapDescription, "Partial-thickness skin loss with exposed dermis")
        XCTAssertEqual(WoundStage.stage3.npiapDescription, "Full-thickness skin loss")
        XCTAssertEqual(WoundStage.stage4.npiapDescription, "Full-thickness skin and tissue loss")
    }

    func testFromClassLabel() {
        // Exact match
        XCTAssertEqual(WoundStage.from(classLabel: "stage1"), .stage1)
        XCTAssertEqual(WoundStage.from(classLabel: "stage4"), .stage4)

        // Variations
        XCTAssertEqual(WoundStage.from(classLabel: "Stage 1"), .stage1)
        XCTAssertEqual(WoundStage.from(classLabel: "Stage-2"), .stage2)
        XCTAssertEqual(WoundStage.from(classLabel: "stage_3"), .stage3)
        XCTAssertEqual(WoundStage.from(classLabel: "STAGE4"), .stage4)

        // Unknown
        XCTAssertNil(WoundStage.from(classLabel: "person"))
        XCTAssertNil(WoundStage.from(classLabel: ""))
    }

    func testAllCasesHaveMaskColor() {
        for stage in WoundStage.allCases {
            // Just verify they don't crash and produce a color
            _ = stage.maskColor
        }
    }
}
