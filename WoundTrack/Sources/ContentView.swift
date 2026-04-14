import SwiftUI

/// Root view of the longitudinal tracking app. The old single-shot flow
/// (photo pick → inference → share) still lives on `main` as a fallback demo.
struct ContentView: View {
    var body: some View {
        PatientListView()
    }
}
