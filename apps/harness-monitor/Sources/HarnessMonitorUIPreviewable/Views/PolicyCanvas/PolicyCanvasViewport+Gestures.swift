import SwiftUI

extension PolicyCanvasViewport {
  /// Trackpad pinch gesture. `MagnifyGesture.Value.startAnchor` carries the
  /// focal point as a unit-space `UnitPoint` over the gesture view's bounds,
  /// which matches what `.scaleEffect(_:anchor:)` expects. Routing the same
  /// `UnitPoint` into the view-model's `pinchAnchorUnit` keeps the content
  /// under the user's fingers stationary in screen space across the pinch.
  ///
  /// `magnifyStartZoom` is captured on first `.onChanged` (the value is the
  /// gesture's baseline zoom, not the running scale), so the per-tick math
  /// is `baseZoom * value.magnification`. `value.magnification` is 1.0 at
  /// pinch start and varies from there.
  func magnifyGesture(in viewportSize: CGSize) -> some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { value in
        let baseZoom = magnifyStartZoomValue ?? viewModel.zoom
        if magnifyStartZoomValue == nil {
          magnifyStartZoomValue = baseZoom
        }
        viewModel.setZoom(baseZoom * value.magnification, anchor: value.startAnchor)
      }
      .onEnded { _ in
        magnifyStartZoomValue = nil
        // Drop the anchor at end-of-gesture so subsequent chrome-button
        // zooms render from the canvas top-leading origin (matching the
        // visual contract of Cmd-+ / Cmd-= / Cmd-- / Cmd-0). The viewport
        // size is captured here only as a future hook — anchors are unit
        // space, so the dimension is not needed for the clear path.
        _ = viewportSize
        viewModel.clearPinchAnchor()
      }
  }
}
