import AppKit
import HarnessMonitorKit

extension PrimaryContentPagingResponderBridgeView {
  enum PagingAction: String {
    case pageDown
    case pageUp
    case scrollPageDown
    case scrollPageUp
  }

  func handlePagingKey(_ event: NSEvent) -> Bool {
    switch event.specialKey {
    case .pageDown?:
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "key-page-down"
      )
      pageDown(self)
      return true
    case .pageUp?:
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "key-page-up"
      )
      pageUp(self)
      return true
    default:
      break
    }

    guard event.charactersIgnoringModifiers == " " else {
      return false
    }

    if event.modifierFlags.contains(.shift) {
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "key-shift-space"
      )
      scrollPageUp(self)
    } else {
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "key-space"
      )
      scrollPageDown(self)
    }
    return true
  }

  func isPagingEvent(_ event: NSEvent) -> Bool {
    pagingAction(for: event) != nil
  }

  func pagingAction(for event: NSEvent) -> PagingAction? {
    switch event.specialKey {
    case .pageDown?:
      return .pageDown
    case .pageUp?:
      return .pageUp
    default:
      guard event.charactersIgnoringModifiers == " " else {
        return nil
      }
      return event.modifierFlags.contains(.shift) ? .scrollPageUp : .scrollPageDown
    }
  }

  func performPagingAction(_ action: PagingAction, sender: Any?) {
    guard let scrollView = resolvedScrollView() else {
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "paging-missing-scroll-view",
        details: ["action": action.rawValue]
      )
      return
    }

    let beforeY = scrollView.documentVisibleRect.minY
    let metrics = pagingMetrics(for: scrollView, visibleRect: scrollView.documentVisibleRect)
    switch action {
    case .pageDown, .scrollPageDown:
      scrollView.pageDown(sender)
    case .pageUp, .scrollPageUp:
      scrollView.pageUp(sender)
    }

    var afterY = scrollView.documentVisibleRect.minY
    let needsFallback = abs(afterY - beforeY) < 1
    if needsFallback {
      let direction: CGFloat
      switch action {
      case .pageDown, .scrollPageDown:
        direction = 1
      case .pageUp, .scrollPageUp:
        direction = -1
      }
      manuallyPage(scrollView, direction: direction)
      afterY = scrollView.documentVisibleRect.minY
    }

    HarnessMonitorUITestTrace.record(
      component: "primary-content-focus",
      event: "paging-action",
      details: [
        "action": action.rawValue,
        "before_y": coordinateLabel(beforeY),
        "after_y": coordinateLabel(afterY),
        "minimum_y": coordinateLabel(metrics.minimumY),
        "maximum_y": coordinateLabel(metrics.maximumY),
        "page_distance": coordinateLabel(metrics.pageDistance),
        "content_inset_top": coordinateLabel(scrollView.contentInsets.top),
        "content_inset_bottom": coordinateLabel(scrollView.contentInsets.bottom),
        "used_manual_fallback": String(needsFallback),
      ]
    )
  }

  func manuallyPage(_ scrollView: NSScrollView, direction: CGFloat) {
    let clipView = scrollView.contentView
    let visibleRect = scrollView.documentVisibleRect
    guard visibleRect.height > 0 else {
      return
    }

    let metrics = pagingMetrics(for: scrollView, visibleRect: visibleRect)
    let proposedY = visibleRect.minY + (metrics.pageDistance * direction)
    let clampedY = min(max(proposedY, metrics.minimumY), metrics.maximumY)
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: clampedY))
    scrollView.reflectScrolledClipView(clipView)
  }

  func pagingMetrics(
    for scrollView: NSScrollView,
    visibleRect: NSRect
  ) -> PagingScrollMetrics {
    let documentBounds = scrollView.documentView?.bounds ?? visibleRect
    let minimumY = documentBounds.minY - scrollView.contentInsets.top
    let maximumY = max(
      documentBounds.maxY - visibleRect.height + scrollView.contentInsets.bottom,
      minimumY
    )
    let pageDistance = preferredPageDistance(for: scrollView, visibleRect: visibleRect)
    return PagingScrollMetrics(minimumY: minimumY, maximumY: maximumY, pageDistance: pageDistance)
  }

  func preferredPageDistance(for scrollView: NSScrollView, visibleRect: NSRect) -> CGFloat {
    let overlap = max(scrollView.lineScroll, 32)
    let computedPageDistance = max(visibleRect.height - overlap, 44)
    return max(scrollView.verticalPageScroll, scrollView.pageScroll, computedPageDistance)
  }
}
