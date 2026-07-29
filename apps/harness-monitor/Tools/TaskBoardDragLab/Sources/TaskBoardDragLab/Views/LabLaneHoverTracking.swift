import Observation
import SwiftUI

@MainActor
@Observable
final class LabLaneHoverTracking {
    var location: CGPoint?
    private(set) var hoveredCardID: String?
    private var frames: [String: CGRect] = [:]

    func setFrame(_ frame: CGRect, for cardID: String) {
        frames[cardID] = frame
        resolveHoveredCard()
    }

    func removeFrame(for cardID: String) {
        frames[cardID] = nil
        resolveHoveredCard()
    }

    func update(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            self.location = location
        case .ended:
            location = nil
        }
        resolveHoveredCard()
    }

    private func resolveHoveredCard() {
        guard let location else {
            hoveredCardID = nil
            return
        }
        hoveredCardID = frames.first { $0.value.contains(location) }?.key
    }
}

extension View {
    func labTrackedCardFrame(
        cardID: String,
        coordinateSpace: String,
        isEnabled: Bool,
        tracking: LabLaneHoverTracking
    ) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(coordinateSpace))
        } action: { frame in
            guard isEnabled else { return }
            tracking.setFrame(frame, for: cardID)
        }
        .onDisappear {
            guard isEnabled else { return }
            tracking.removeFrame(for: cardID)
        }
    }
}
