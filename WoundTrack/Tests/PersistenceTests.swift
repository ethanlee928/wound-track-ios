import SwiftData
import XCTest
@testable import WoundDetector

final class PersistenceTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() async throws {
        let schema = Schema([Patient.self, Wound.self, Assessment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Test 4: cascade delete removes wounds + assessments

    func testDeletingPatientCascadesToWoundsAndAssessments() async throws {
        let store = WoundStore(modelContainer: container)
        let patientID = try await store.createPatient(name: "Jane Doe", mrn: "A1")
        let woundID = try await store.createWound(patientID: patientID, bodySite: .sacrum)
        _ = try await store.createAssessment(
            woundID: woundID,
            imageRelativePath: "assessments/test.jpg",
            areaCm2: 4.2
        )

        // Verify row counts before deletion.
        let ctx = ModelContext(container)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Patient>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Wound>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Assessment>()), 1)

        try await store.deletePatient(patientID)

        // Recreate a fresh context to avoid stale snapshots.
        let ctx2 = ModelContext(container)
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<Patient>()), 0)
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<Wound>()), 0, "Wounds must cascade")
        XCTAssertEqual(try ctx2.fetchCount(FetchDescriptor<Assessment>()), 0, "Assessments must cascade")
    }

    // MARK: - Test 4b: round-trip relationships

    func testAssessmentsReachableFromPatientAfterRefetch() async throws {
        let store = WoundStore(modelContainer: container)
        let patientID = try await store.createPatient(name: "Bob", mrn: nil)
        let woundID = try await store.createWound(patientID: patientID, bodySite: .leftHeel)
        _ = try await store.createAssessment(
            woundID: woundID, imageRelativePath: "x.jpg", areaCm2: 1.0
        )

        let ctx = ModelContext(container)
        let patients = try ctx.fetch(FetchDescriptor<Patient>())
        XCTAssertEqual(patients.count, 1)
        let patient = patients[0]
        XCTAssertEqual(patient.wounds.count, 1)
        XCTAssertEqual(patient.wounds[0].bodySite, .leftHeel)
        XCTAssertEqual(patient.wounds[0].assessments.count, 1)
        XCTAssertEqual(patient.wounds[0].assessments[0].areaCm2, 1.0)
    }

    // MARK: - Test 5: BodySite enum stability

    func testBodySiteRawValuesAreStableStrings() {
        // Raw values are load-bearing — SwiftData stores these, so changing them
        // breaks existing patient records. Lock them down with this test.
        XCTAssertEqual(BodySite.sacrum.rawValue, "sacrum")
        XCTAssertEqual(BodySite.leftHeel.rawValue, "left_heel")
        XCTAssertEqual(BodySite.rightHeel.rawValue, "right_heel")
        XCTAssertEqual(BodySite.leftTrochanter.rawValue, "left_trochanter")
        XCTAssertEqual(BodySite.rightTrochanter.rawValue, "right_trochanter")
        XCTAssertEqual(BodySite.leftIschium.rawValue, "left_ischium")
        XCTAssertEqual(BodySite.rightIschium.rawValue, "right_ischium")
        XCTAssertEqual(BodySite.leftFirstMT.rawValue, "left_first_mt")
        XCTAssertEqual(BodySite.rightFirstMT.rawValue, "right_first_mt")
        XCTAssertEqual(BodySite.other.rawValue, "other")
    }

    func testBodySiteDecodeFromRawSurvivesEnumReorder() {
        // Simulate "someone added a new case at the top" — decoding by raw
        // string must still work for every known value.
        for site in BodySite.allCases {
            let decoded = BodySite(rawValue: site.rawValue)
            XCTAssertEqual(decoded, site, "\(site.rawValue) did not round-trip")
        }
    }
}
