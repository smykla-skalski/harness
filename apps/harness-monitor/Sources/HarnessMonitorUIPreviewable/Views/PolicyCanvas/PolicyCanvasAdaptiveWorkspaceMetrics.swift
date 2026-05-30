import Foundation
import SwiftUI

struct PolicyCanvasAdaptiveWorkspaceLayout: Equatable, Sendable {
  let contentSize: CGSize
  let contentOrigin: CGPoint
  let workspaceSize: CGSize

  var trailingInset: CGFloat {
    max(0, workspaceSize.width - contentOrigin.x - contentSize.width)
  }

  var bottomInset: CGFloat {
    max(0, workspaceSize.height - contentOrigin.y - contentSize.height)
  }

  func workspacePoint(forContentPoint point: CGPoint) -> CGPoint {
    CGPoint(x: point.x + contentOrigin.x, y: point.y + contentOrigin.y)
  }

  func contentPoint(forWorkspacePoint point: CGPoint) -> CGPoint {
    CGPoint(x: point.x - contentOrigin.x, y: point.y - contentOrigin.y)
  }

  func contentRect(forWorkspaceRect rect: CGRect) -> CGRect {
    CGRect(origin: contentPoint(forWorkspacePoint: rect.origin), size: rect.size)
  }
}

struct PolicyCanvasAdaptiveWorkspaceExpansion: Equatable, Sendable {
  let layout: PolicyCanvasAdaptiveWorkspaceLayout
  let scrollAdjustment: CGPoint
}

func policyCanvasAdaptiveWorkspaceLayout(
  current: PolicyCanvasAdaptiveWorkspaceLayout?,
  contentSize: CGSize,
  viewportSize: CGSize
) -> PolicyCanvasAdaptiveWorkspaceLayout {
  let effectiveViewportSize = policyCanvasAdaptiveWorkspaceEffectiveViewportSize(
    viewportSize
  )
  let guardBand = policyCanvasAdaptiveWorkspaceGuardBand(
    viewportSize: effectiveViewportSize
  )
  guard let current else {
    return policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: contentSize,
      viewportSize: effectiveViewportSize
    )
  }
  return PolicyCanvasAdaptiveWorkspaceLayout(
    contentSize: contentSize,
    contentOrigin: current.contentOrigin,
    workspaceSize: CGSize(
      width: max(
        current.workspaceSize.width,
        current.contentOrigin.x + contentSize.width + max(current.trailingInset, guardBand.width)
      ),
      height: max(
        current.workspaceSize.height,
        current.contentOrigin.y + contentSize.height + max(current.bottomInset, guardBand.height)
      )
    )
  )
}

func policyCanvasInitialAdaptiveWorkspaceLayout(
  contentSize: CGSize,
  viewportSize: CGSize
) -> PolicyCanvasAdaptiveWorkspaceLayout {
  let effectiveViewportSize = policyCanvasAdaptiveWorkspaceEffectiveViewportSize(
    viewportSize
  )
  let guardBand = policyCanvasAdaptiveWorkspaceGuardBand(
    viewportSize: effectiveViewportSize
  )
  return PolicyCanvasAdaptiveWorkspaceLayout(
    contentSize: contentSize,
    contentOrigin: CGPoint(x: guardBand.width, y: guardBand.height),
    workspaceSize: CGSize(
      width: contentSize.width + (guardBand.width * 2),
      height: contentSize.height + (guardBand.height * 2)
    )
  )
}

func policyCanvasExpandedAdaptiveWorkspaceLayout(
  layout: PolicyCanvasAdaptiveWorkspaceLayout,
  visibleWorkspaceRect: CGRect,
  viewportSize: CGSize
) -> PolicyCanvasAdaptiveWorkspaceExpansion {
  let effectiveViewportSize = policyCanvasAdaptiveWorkspaceEffectiveViewportSize(
    viewportSize
  )
  let growth = policyCanvasAdaptiveWorkspaceGuardBand(
    viewportSize: effectiveViewportSize
  )
  var contentOrigin = layout.contentOrigin
  var workspaceSize = layout.workspaceSize
  var scrollAdjustment = CGPoint.zero

  if visibleWorkspaceRect.minX < growth.width {
    contentOrigin.x += growth.width
    workspaceSize.width += growth.width
    scrollAdjustment.x += growth.width
  }
  if visibleWorkspaceRect.minY < growth.height {
    contentOrigin.y += growth.height
    workspaceSize.height += growth.height
    scrollAdjustment.y += growth.height
  }
  if (workspaceSize.width - visibleWorkspaceRect.maxX) < growth.width {
    workspaceSize.width += growth.width
  }
  if (workspaceSize.height - visibleWorkspaceRect.maxY) < growth.height {
    workspaceSize.height += growth.height
  }

  return PolicyCanvasAdaptiveWorkspaceExpansion(
    layout: PolicyCanvasAdaptiveWorkspaceLayout(
      contentSize: layout.contentSize,
      contentOrigin: contentOrigin,
      workspaceSize: workspaceSize
    ),
    scrollAdjustment: scrollAdjustment
  )
}

private func policyCanvasAdaptiveWorkspaceGuardBand(
  viewportSize: CGSize
) -> CGSize {
  CGSize(
    width: max(PolicyCanvasLayout.canvasTrailingPadding, viewportSize.width * 1.5),
    height: max(PolicyCanvasLayout.canvasBottomPadding, viewportSize.height * 1.5)
  )
}

private func policyCanvasAdaptiveWorkspaceEffectiveViewportSize(
  _ viewportSize: CGSize
) -> CGSize {
  CGSize(
    width: max(640, viewportSize.width),
    height: max(480, viewportSize.height)
  )
}
