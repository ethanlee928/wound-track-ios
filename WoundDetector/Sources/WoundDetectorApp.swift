import SwiftUI
import SwiftData

@main
struct WoundDetectorApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Patient.self, Wound.self, Assessment.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
