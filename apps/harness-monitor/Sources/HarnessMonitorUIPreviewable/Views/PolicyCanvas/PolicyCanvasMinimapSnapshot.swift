import Foundation

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
  /// current viewport on the policy content bounds. A minimap click recenters
  /// on the policy regardless of where in the minimap the click landed.
  var viewportOriginCenteredOnContent: CGPoint {
    CGPoint(
      x: contentBounds.midX - (viewportRect.width / 2),
      y: contentBounds.midY - (viewportRect.height / 2)
    )
  }
}

struct PolicyCanvasMinimapProjection: Equatable, Sendable {
  let snapshot: PolicyCanvasMinimapSnapshot
  let minimapSize: CGSize
  let scale: CGFloat
  let contentFrame: CGRect

  func rect(forCanvasRect rect: CGRect) -> CGRect {
    CGRect(
      x: contentFrame.minX + ((rect.minX - snapshot.worldBounds.minX) * scale),
      y: contentFrame.minY + ((rect.minY - snapshot.worldBounds.minY) * scale),
      width: rect.width * scale,
      height: rect.height * scale
    )
  }

  func canvasTranslation(forMinimapTranslation translation: CGSize) -> CGSize {
    CGSize(width: translation.width / scale, height: translation.height / scale)
  }
}

func policyCanvasMinimapSnapshot(
  contentBounds: CGRect,
  viewportRect: CGRect,
  nodeFrames: [CGRect],
  groupFrames: [CGRect]
) -> PolicyCanvasMinimapSnapshot {
  let worldBounds = contentBounds.union(viewportRect)
  return PolicyCanvasMinimapSnapshot(
    contentBounds: contentBounds,
    worldBounds: worldBounds,
    nodeFrames: nodeFrames,
    groupFrames: groupFrames,
    viewportRect: viewportRect
  )
}

func policyCanvasMinimapProjection(
  snapshot: PolicyCanvasMinimapSnapshot,
  minimapSize: CGSize
) -> PolicyCanvasMinimapProjection {
  let safeSize = CGSize(
    width: max(1, minimapSize.width),
    height: max(1, minimapSize.height)
  )
  let scale = min(
    safeSize.width / snapshot.worldBounds.width,
    safeSize.height / snapshot.worldBounds.height
  )
  let fittedSize = CGSize(
    width: snapshot.worldBounds.width * scale,
    height: snapshot.worldBounds.height * scale
  )
  let contentFrame = CGRect(
    x: (safeSize.width - fittedSize.width) / 2,
    y: (safeSize.height - fittedSize.height) / 2,
    width: fittedSize.width,
    height: fittedSize.height
  )
  return PolicyCanvasMinimapProjection(
    snapshot: snapshot,
    minimapSize: safeSize,
    scale: scale,
    contentFrame: contentFrame
  )
}

/// Movement (in minimap-local points) at or below which a viewport drag gesture
/// is treated as a click rather than a pan. A click recenters the viewport on
/// the policy; a longer drag pans it.
let policyCanvasMinimapClickMovementThreshold: CGFloat = 4

func policyCanvasMinimapGestureIsClick(translation: CGSize) -> Bool {
  hypot(translation.width, translation.height) <= policyCanvasMinimapClickMovementThreshold
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
