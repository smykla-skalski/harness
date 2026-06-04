import AppKit

extension PolicyCanvasNativeScrollView {
  func markDocumentRootLaidOutIfPossible() {
    if documentView != nil, contentView.bounds.width > 1, contentView.bounds.height > 1 {
      hasLaidOutDocumentRootInViewport = true
    }
  }

  func reflectDocumentRootUpdate(shouldExpand: Bool) {
    super.reflectScrolledClipView(contentView)
    guard shouldExpand else {
      return
    }
    expandAdaptiveWorkspaceIfNeeded()
  }

  func visibleContentCenterToPreserve() -> CGPoint? {
    guard
      let adaptiveWorkspaceLayout,
      contentView.bounds.width > 1,
      contentView.bounds.height > 1,
      documentView != nil
    else {
      return nil
    }
    return visibleContentCenter(in: adaptiveWorkspaceLayout)
  }

  func visibleContentCenter(
    in workspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout
  ) -> CGPoint {
    let visibleContentRect = workspaceLayout.contentRect(forWorkspaceRect: visibleWorkspaceRect)
    return CGPoint(x: visibleContentRect.midX, y: visibleContentRect.midY)
  }

  func scrollToPreserveContentCenter(
    _ contentCenter: CGPoint,
    in workspaceLayout: PolicyCanvasAdaptiveWorkspaceLayout
  ) {
    let workspaceCenter = workspaceLayout.workspacePoint(forContentPoint: contentCenter)
    let targetOrigin = CGPoint(
      x: workspaceCenter.x - (contentView.bounds.width / 2),
      y: workspaceCenter.y - (contentView.bounds.height / 2)
    )
    guard
      abs(contentView.bounds.origin.x - targetOrigin.x) > 0.5
        || abs(contentView.bounds.origin.y - targetOrigin.y) > 0.5
    else {
      return
    }
    isPreservingViewportCenter = true
    contentView.scroll(to: targetOrigin)
    super.reflectScrolledClipView(contentView)
    isPreservingViewportCenter = false
  }

  func scrollToPreserveContentCenterIfPossible(_ contentCenter: CGPoint) {
    guard let adaptiveWorkspaceLayout else {
      return
    }
    scrollToPreserveContentCenter(contentCenter, in: adaptiveWorkspaceLayout)
  }

  func reportViewportStateIfNeeded() {
    let observedState = PolicyCanvasViewportObservedState(
      visibleContentRect: adaptiveWorkspaceLayout?.contentRect(
        forWorkspaceRect: visibleWorkspaceRect)
        ?? visibleWorkspaceRect,
      zoom: magnification
    )
    guard !approximatelyMatchesLastReportedViewportState(observedState) else {
      return
    }
    lastReportedViewportState = observedState
    viewportDidChange?(observedState)
  }

  private func approximatelyMatchesLastReportedViewportState(
    _ observedState: PolicyCanvasViewportObservedState
  ) -> Bool {
    guard let lastReportedViewportState else {
      return false
    }
    return abs(lastReportedViewportState.zoom - observedState.zoom) < 0.001
      && abs(
        lastReportedViewportState.visibleContentRect.minX - observedState.visibleContentRect.minX)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.minY - observedState.visibleContentRect.minY)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.width - observedState.visibleContentRect.width)
        < 0.5
      && abs(
        lastReportedViewportState.visibleContentRect.height
          - observedState.visibleContentRect.height)
        < 0.5
  }
}
