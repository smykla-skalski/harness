// Companion to PolicyCanvasNativeScrollView.swift.
// Adaptive-workspace expansion logic for PolicyCanvasNativeScrollView.
import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasNativeScrollView {
  func expandAdaptiveWorkspaceIfNeeded() {
    guard
      !isAdjustingAdaptiveWorkspace,
      adaptiveExpansionArmed,
      let adaptiveWorkspaceLayout,
      let hostedDocumentView = documentView as? PolicyCanvasNativeDocumentView,
      contentView.bounds.width > 1,
      contentView.bounds.height > 1
    else {
      return
    }

    let expansion = policyCanvasExpandedAdaptiveWorkspaceLayout(
      layout: adaptiveWorkspaceLayout,
      visibleWorkspaceRect: visibleWorkspaceRect,
      viewportSize: contentView.bounds.size
    )
    guard expansion.layout != adaptiveWorkspaceLayout else {
      return
    }

    isAdjustingAdaptiveWorkspace = true
    self.adaptiveWorkspaceLayout = expansion.layout
    hostedDocumentView.hostedState.update(workspaceLayout: expansion.layout)
    hostedDocumentView.updateSize(expansion.layout.workspaceSize)

    if expansion.scrollAdjustment != .zero {
      let visibleOrigin = visibleWorkspaceRect.origin
      contentView.scroll(
        to: CGPoint(
          x: visibleOrigin.x + expansion.scrollAdjustment.x,
          y: visibleOrigin.y + expansion.scrollAdjustment.y
        )
      )
    }

    super.reflectScrolledClipView(contentView)
    isAdjustingAdaptiveWorkspace = false
    reportViewportStateIfNeeded()
  }

  func expandAdaptiveWorkspaceIfNeeded(
    toContainViewportOrigin targetOrigin: CGPoint
  ) -> CGPoint {
    guard
      let adaptiveWorkspaceLayout,
      let hostedDocumentView = documentView as? PolicyCanvasNativeDocumentView,
      contentView.bounds.width > 1,
      contentView.bounds.height > 1
    else {
      return targetOrigin
    }

    let guardBand = policyCanvasAdaptiveWorkspaceGuardBand(
      viewportSize: contentView.bounds.size
    )
    var contentOrigin = adaptiveWorkspaceLayout.contentOrigin
    var workspaceSize = adaptiveWorkspaceLayout.workspaceSize
    var adjustedTargetOrigin = targetOrigin

    if targetOrigin.x < 0 {
      let growth = -targetOrigin.x + guardBand.width
      contentOrigin.x += growth
      workspaceSize.width += growth
      adjustedTargetOrigin.x += growth
    }
    if targetOrigin.y < 0 {
      let growth = -targetOrigin.y + guardBand.height
      contentOrigin.y += growth
      workspaceSize.height += growth
      adjustedTargetOrigin.y += growth
    }

    let expandedWorkspaceSize = CGSize(
      width: max(
        workspaceSize.width,
        adjustedTargetOrigin.x + contentView.bounds.width
      ),
      height: max(
        workspaceSize.height,
        adjustedTargetOrigin.y + contentView.bounds.height
      )
    )

    let expandedLayout = PolicyCanvasAdaptiveWorkspaceLayout(
      contentSize: adaptiveWorkspaceLayout.contentSize,
      contentOrigin: contentOrigin,
      workspaceSize: expandedWorkspaceSize
    )
    guard expandedLayout != adaptiveWorkspaceLayout else {
      return adjustedTargetOrigin
    }
    isAdjustingAdaptiveWorkspace = true
    self.adaptiveWorkspaceLayout = expandedLayout
    hostedDocumentView.hostedState.update(workspaceLayout: expandedLayout)
    hostedDocumentView.updateSize(expandedWorkspaceSize)
    isAdjustingAdaptiveWorkspace = false
    return adjustedTargetOrigin
  }
}
