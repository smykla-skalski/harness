import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

// CHERRY-PICK NOTE: When merging on top of Wave 2D, ensure
// restoreState(_:) in PolicyCanvasViewModel+Document.swift also calls
// resetPaletteDropPlacement(). Otherwise, after a daemon-reject restore the
// palette anchor keeps drifting because the diagonal cursor is never rewound
// to PolicyCanvasLayout.initialPaletteDropAnchor. The same-revision republish
// path in applyDocument already calls it post-fix-up (Wave 2F Item 1).

extension PolicyCanvasViewModel {
  /// Compute the next palette-click drop position. Each click advances by a
  /// fixed offset (40pt grid step) along a diagonal so a user clicking the
  /// same palette button multiple times sees separate nodes instead of one
  /// node stacking on itself. When the next slot collides with an existing
  /// node, the cursor advances diagonally until it lands in clear space.
  func nextPaletteDropCenter() -> CGPoint {
    var candidate = nextPaletteDropAnchor
    let limit = 24
    var iteration = 0
    while occupied(at: candidate), iteration < limit {
      candidate = advance(candidate)
      iteration += 1
    }
    nextPaletteDropAnchor = advance(candidate)
    return candidate
  }

  /// Reset palette-drop placement state after a load or canvas wipe so the
  /// next click lands at the initial anchor again.
  func resetPaletteDropPlacement() {
    nextPaletteDropAnchor = PolicyCanvasLayout.initialPaletteDropAnchor
  }

  private func occupied(at center: CGPoint) -> Bool {
    let frame = CGRect(
      x: center.x - PolicyCanvasLayout.nodeSize.width / 2,
      y: center.y - PolicyCanvasLayout.nodeSize.height / 2,
      width: PolicyCanvasLayout.nodeSize.width,
      height: PolicyCanvasLayout.nodeSize.height
    )
    return nodes.contains { node in
      CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize).intersects(frame)
    }
  }

  private func advance(_ point: CGPoint) -> CGPoint {
    let step = PolicyCanvasLayout.paletteDropStep
    return CGPoint(x: point.x + step, y: point.y + step)
  }
}
