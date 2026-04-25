import Foundation

/// Removes files in the app's Documents directory given their relative paths.
/// Used after cascading SwiftData deletes so disk storage stays reconciled.
enum FileCleanup {
    static func removeRelative(paths: [String]) {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        for rel in paths where !rel.isEmpty {
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(rel))
        }
    }
}
