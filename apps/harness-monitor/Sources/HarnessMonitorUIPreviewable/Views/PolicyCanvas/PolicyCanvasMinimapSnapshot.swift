import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasMinimapSnapshot: Equatable, Sendable {
  let contentBounds: CGRect
  let worldBounds: CGRect
  let nodeFrames: [CGRect]
  let groupFrames: [CGRect]
  let viewportRect: CGRect

  init(
    contentBounds: CGRect,
    worldBounds: CGRect,
    nodeFrames: [CGRect],
    groupFrames: [CGRect],
    viewportRect: CGRect
  ) {
    self.contentBounds = policyCanvasNormalizedMinimapBounds(contentBounds)
    self.worldBounds = policyCanvasNormalizedMinimapBounds(worldBounds)
    self.nodeFrames = nodeFrames
    self.groupFrames = groupFrames
    self.viewportRect = viewportRect
  }

  /// Viewport origin (top-left, in content/world coordinates) that centers the
  /// current viewport on the policy content bounds. The minimap center button
  /// uses this target regardless of where the viewport currently sits.
  var viewportOriginCenteredOnContent: CGPoint {
    CGPoint(
      x: contentBounds.midX - (viewportRect.width / 2),
      y: contentBounds.midY - (viewportRect.height / 2)
    )
  }
}

struct PolicyCanvasMinimapProjection: Equatable, Sendable {
  let worldBounds: CGRect
  let minimapSize: CGSize
  let scale: CGFloat
  let contentFrame: CGRect

  func rect(forCanvasRect rect: CGRect) -> CGRect {
    CGRect(
      x: contentFrame.minX + ((rect.minX - worldBounds.minX) * scale),
      y: contentFrame.minY + ((rect.minY - worldBounds.minY) * scale),
      width: rect.width * scale,
      height: rect.height * scale
    )
  }

  func canvasTranslation(forMinimapTranslation translation: CGSize) -> CGSize {
    CGSize(width: translation.width / scale, height: translation.height / scale)
  }
}

/// Clamps the projected viewport indicator so it stays fully inside the minimap
/// drawable bounds. The minimap world is pinned to the policy content (so the
/// graph thumbnail never rescales when the live viewport resizes), which means a
/// viewport larger than - or panned off - the content would otherwise project
/// outside the minimap. Clamping keeps the indicator visible against the nearest
/// edge instead of expanding the world to chase it.
func policyCanvasMinimapClampedViewportIndicator(
  _ projectedViewport: CGRect,
  in minimapSize: CGSize,
  minimumExtent: CGFloat = 18
) -> CGRect {
  let width = min(max(minimumExtent, projectedViewport.width), minimapSize.width)
  let height = min(max(minimumExtent, projectedViewport.height), minimapSize.height)
  let centerX = min(max(width / 2, projectedViewport.midX), minimapSize.width - (width / 2))
  let centerY = min(max(height / 2, projectedViewport.midY), minimapSize.height - (height / 2))
  return CGRect(
    x: centerX - (width / 2),
    y: centerY - (height / 2),
    width: width,
    height: height
  )
}

func policyCanvasMinimapSnapshot(
  contentBounds: CGRect,
  viewportRect: CGRect,
  nodeFrames: [CGRect],
  groupFrames: [CGRect]
) -> PolicyCanvasMinimapSnapshot {
  // The minimap world is the policy content alone - deliberately NOT unioned
  // with the live viewport. Folding the viewport in here made the world (and so
  // the whole thumbnail projection) rescale whenever the viewport moved or
  // resized, so toggling the inspector pane visibly redrew and shifted the
  // graph. Pinning the world to the content keeps the thumbnail stable across
  // viewport changes; the viewport indicator is clamped to the minimap bounds
  // instead (see `policyCanvasMinimapClampedViewportIndicator`).
  PolicyCanvasMinimapSnapshot(
    contentBounds: contentBounds,
    worldBounds: contentBounds,
    nodeFrames: nodeFrames,
    groupFrames: groupFrames,
    viewportRect: viewportRect
  )
}

func policyCanvasMinimapProjection(
  snapshot: PolicyCanvasMinimapSnapshot,
  minimapSize: CGSize
) -> PolicyCanvasMinimapProjection {
  policyCanvasMinimapProjection(worldBounds: snapshot.worldBounds, minimapSize: minimapSize)
}

func policyCanvasMinimapProjection(
  worldBounds: CGRect,
  minimapSize: CGSize
) -> PolicyCanvasMinimapProjection {
  let safeSize = CGSize(
    width: max(1, minimapSize.width),
    height: max(1, minimapSize.height)
  )
  let safeWorld = policyCanvasNormalizedMinimapBounds(worldBounds)
  let scale = min(
    safeSize.width / safeWorld.width,
    safeSize.height / safeWorld.height
  )
  let fittedSize = CGSize(
    width: safeWorld.width * scale,
    height: safeWorld.height * scale
  )
  let contentFrame = CGRect(
    x: (safeSize.width - fittedSize.width) / 2,
    y: (safeSize.height - fittedSize.height) / 2,
    width: fittedSize.width,
    height: fittedSize.height
  )
  return PolicyCanvasMinimapProjection(
    worldBounds: safeWorld,
    minimapSize: safeSize,
    scale: scale,
    contentFrame: contentFrame
  )
}

private func policyCanvasNormalizedMinimapBounds(_ rect: CGRect) -> CGRect {
  let normalized = rect.standardized
  return CGRect(
    x: normalized.minX,
    y: normalized.minY,
    width: max(1, normalized.width),
    height: max(1, normalized.height)
  )
}
