import SwiftUI

extension PolicyCanvasViewModel {
  // MARK: - Chrome action stubs

  /// View-side intent: user clicked the Save button. The host view runs the
  /// actual daemon round-trip; this method only nudges status and view state.
  func save() {
    notifyStatus("Draft saved")
  }

  /// View-side intent: user clicked the Simulate button. Switches the tab to
  /// `.simulation` and emits status; daemon work runs in the host view.
  func simulate() {
    selectedTab = .simulation
    notifyStatus("Simulation queued")
  }

  /// View-side intent: user requested promotion. Switches the tab to
  /// `.promotion` and emits status; daemon work runs in the host view.
  func promote() {
    selectedTab = .promotion
    notifyStatus("Promotion requested")
  }

  // MARK: - Status emission

  /// Emit a human-readable status update to the host view. No-op when the host
  /// has not yet wired a `statusCallback`, which keeps unit-test paths quiet.
  func notifyStatus(_ status: String) {
    statusCallback?(status)
  }

  // MARK: - Viewport (zoom)

  func zoomIn() {
    setZoom(zoom + 0.1)
  }

  func zoomOut() {
    setZoom(zoom - 0.1)
  }

  func resetZoom() {
    setZoom(1)
  }

  /// Updates the canvas zoom and marks the viewport (not the document) dirty.
  /// Viewport state is window-scoped layout, not part of the saved pipeline,
  /// so `documentDirty` stays untouched.
  func setZoom(_ value: CGFloat) {
    zoom = min(1.4, max(0.6, value))
    viewportDirty = true
  }
}
