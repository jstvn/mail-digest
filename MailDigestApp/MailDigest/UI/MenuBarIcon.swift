import AppKit
import SwiftUI

/// What the menu bar icon shows besides the pending count.
enum MenuBarIconState: Hashable {
    case idle
    /// A job is listing mail or has no total yet: a ring that is not filled.
    case listing
    /// A job is running; `step` is progress in 5% steps (0...20).
    case progress(step: Int)
    /// A job is paused.
    case paused

    /// Spoken after "Mail Digest".
    var accessibilityText: String? {
        switch self {
        case .idle: return nil
        case .listing: return "looking for mail"
        case .progress(let step): return "processing, \(min(step * 5, 100)) percent"
        case .paused: return "job paused"
        }
    }
}

/// Draws the menu bar icon with a progress ring or pause badge as a template image, so the status item
/// stays a standard `NSStatusBarButton` image: the system tints it for light, dark and highlighted states.
@MainActor
enum MenuBarIconRenderer {
    private static var cache: [MenuBarIconState: NSImage] = [:]

    /// The composite icon, or nil for `.idle` (the plain symbol is used then). Cached per state.
    static func image(for state: MenuBarIconState) -> NSImage? {
        guard state != .idle else { return nil }
        if let cached = cache[state] { return cached }
        let renderer = ImageRenderer(content: IconView(state: state))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        cache[state] = image
        return image
    }

    private struct IconView: View {
        let state: MenuBarIconState
        private let size: CGFloat = 18
        private let badge: CGFloat = 9

        var body: some View {
            ZStack(alignment: .topLeading) {
                Image(systemName: "envelope")
                    .font(.system(size: 11.5, weight: .regular))
                    .frame(width: 15, height: 12)
                    // Leave a small gap around the badge so the two shapes don't merge.
                    .mask {
                        Rectangle()
                            .overlay {
                                Circle().frame(width: badge + 3, height: badge + 3)
                                    // Centre of the badge, relative to the middle of the envelope's frame.
                                    .offset(x: size - badge / 2 - 7.5, y: size - badge / 2 - 1 - 6)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                    .offset(x: 0, y: 1)
                badgeView
                    .frame(width: badge, height: badge)
                    .offset(x: size - badge, y: size - badge)
            }
            .foregroundStyle(.black) // template images only use alpha
            .frame(width: size, height: size, alignment: .topLeading)
        }

        @ViewBuilder private var badgeView: some View {
            switch state {
            case .paused:
                ZStack {
                    Circle().fill(.black)
                    // Two bars knocked out of the filled disc.
                    HStack(spacing: 1.5) {
                        Rectangle().frame(width: 1.5, height: 4)
                        Rectangle().frame(width: 1.5, height: 4)
                    }
                    .blendMode(.destinationOut)
                }
                .compositingGroup()
            case .progress(let step):
                ring(fraction: Double(step) / 20)
            default:
                ring(fraction: 0)
            }
        }

        private func ring(fraction: Double) -> some View {
            ZStack {
                Circle().stroke(.black.opacity(0.35), lineWidth: 1.6)
                Circle().trim(from: 0, to: max(fraction, 0.04))
                    .stroke(.black, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(0.8)
        }
    }
}
