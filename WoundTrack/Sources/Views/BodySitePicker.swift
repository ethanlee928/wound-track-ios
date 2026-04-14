import SwiftUI

/// Schematic anatomical picker: a stylised posterior-view torso + feet silhouette
/// with tappable dots at each supported pressure-injury site. Cheaper than an
/// SVG but clinically readable — sacrum, trochanters, ischia are all in their
/// anatomically correct positions.
///
/// Selection updates `selection`; selected dot is filled, others are hollow.
struct BodySitePicker: View {
    @Binding var selection: BodySite

    // Positions are in a 200×360 normalized space; the container scales them.
    private struct Dot: Identifiable {
        let id = UUID()
        let site: BodySite
        let position: CGPoint  // normalized (0-1)
    }

    private let dots: [Dot] = [
        .init(site: .sacrum,          position: CGPoint(x: 0.50, y: 0.42)),
        .init(site: .leftTrochanter,  position: CGPoint(x: 0.28, y: 0.43)),
        .init(site: .rightTrochanter, position: CGPoint(x: 0.72, y: 0.43)),
        .init(site: .leftIschium,     position: CGPoint(x: 0.38, y: 0.50)),
        .init(site: .rightIschium,    position: CGPoint(x: 0.62, y: 0.50)),
        .init(site: .leftHeel,        position: CGPoint(x: 0.38, y: 0.92)),
        .init(site: .rightHeel,       position: CGPoint(x: 0.62, y: 0.92)),
        .init(site: .leftFirstMT,     position: CGPoint(x: 0.32, y: 0.97)),
        .init(site: .rightFirstMT,    position: CGPoint(x: 0.68, y: 0.97)),
    ]

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    BodyOutline()
                        .stroke(Color.secondary.opacity(0.6), lineWidth: 2)
                        .fill(Color(.systemGray6))
                    ForEach(dots) { dot in
                        let center = CGPoint(x: dot.position.x * w, y: dot.position.y * h)
                        let isSelected = selection == dot.site
                        Button {
                            selection = dot.site
                        } label: {
                            Circle()
                                .fill(isSelected ? Color.blue : Color.white)
                                .overlay(Circle().stroke(Color.blue, lineWidth: 2))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .position(center)
                    }
                }
            }
            .frame(height: 360)
            .padding(.horizontal)

            Text(selection.displayName)
                .font(.headline)

            Picker("Other site", selection: $selection) {
                ForEach([BodySite.other]) { Text("Other").tag($0) }
                ForEach(BodySite.allCases.filter { $0 != .other }) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
        }
    }
}

/// Stylised posterior-view body outline: rounded torso + two legs + two feet.
/// Drawn in a normalised 1×1 coordinate space and scaled by the container.
private struct BodyOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height

        // Torso (rounded rectangle from shoulders to hips)
        p.addRoundedRect(
            in: CGRect(x: 0.28 * w, y: 0.10 * h, width: 0.44 * w, height: 0.40 * h),
            cornerSize: CGSize(width: 0.08 * w, height: 0.08 * h)
        )

        // Neck + head
        p.addRoundedRect(
            in: CGRect(x: 0.42 * w, y: 0.02 * h, width: 0.16 * w, height: 0.10 * h),
            cornerSize: CGSize(width: 0.04 * w, height: 0.04 * h)
        )

        // Left leg
        p.addRoundedRect(
            in: CGRect(x: 0.30 * w, y: 0.50 * h, width: 0.16 * w, height: 0.40 * h),
            cornerSize: CGSize(width: 0.04 * w, height: 0.04 * h)
        )
        // Right leg
        p.addRoundedRect(
            in: CGRect(x: 0.54 * w, y: 0.50 * h, width: 0.16 * w, height: 0.40 * h),
            cornerSize: CGSize(width: 0.04 * w, height: 0.04 * h)
        )
        // Left foot
        p.addEllipse(in: CGRect(x: 0.28 * w, y: 0.88 * h, width: 0.20 * w, height: 0.10 * h))
        // Right foot
        p.addEllipse(in: CGRect(x: 0.52 * w, y: 0.88 * h, width: 0.20 * w, height: 0.10 * h))

        return p
    }
}
