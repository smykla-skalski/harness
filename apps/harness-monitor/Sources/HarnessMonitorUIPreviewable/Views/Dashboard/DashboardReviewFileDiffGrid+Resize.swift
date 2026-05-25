import AppKit
import HarnessMonitorKit

@MainActor
extension DashboardReviewFileDiffGridContentView {
  /// Debounce window before a deferred re-wrap runs. Long enough that a 60fps
  /// resize animation (a frame every ~16ms) keeps rescheduling it, so the heavy
  /// re-wrap fires once after the gesture settles rather than on every frame.
  static let wrapLayoutCoalesceDelay: TimeInterval = 0.05

  /// Resize entry for the scroll view's per-frame `layout()` pass. The first
  /// pass (or one right after `configure`) wraps synchronously so the next draw
  /// is correct; a later width change is a live gesture (sidebar collapse,
  /// window resize), so the O(rows) re-wrap is coalesced to when the width
  /// settles. Intermediate frames only resize the canvas and redraw visible
  /// rows from the current layouts.
  func relayoutForViewportResize(_ viewportWidth: CGFloat) {
    let width = contentWidth(viewportWidth: viewportWidth)
    // First paint, or the pass right after `configure` cleared the layouts:
    // wrap synchronously so the next draw is correct.
    guard lastWrappedContentWidth >= 0, wrappedRowLayouts.count == rows.count else {
      resizeForViewportWidth(viewportWidth)
      return
    }
    // Width settled back onto the wrapped width: drop any deferred pass and make
    // sure the canvas matches the already-wrapped geometry.
    guard width != lastWrappedContentWidth else {
      cancelPendingWrapLayout()
      pendingWrapViewportWidth = nil
      applyWrappedContentSize(width)
      return
    }
    // Live resize gesture (sidebar collapse, window drag): defer the O(rows)
    // re-wrap until the width settles. Track the canvas width cheaply and redraw
    // visible rows from the current layouts; `schedulePendingWrapLayout` re-wraps
    // once the gesture stops, so the animation never re-wraps the whole document
    // on every frame.
    pendingWrapViewportWidth = viewportWidth
    applyWrappedContentSize(width)
    needsDisplay = true
    schedulePendingWrapLayout()
  }

  /// Resize the canvas to `contentWidth` from the current (possibly stale during
  /// a coalesced resize) wrapped row heights, without recomputing the wrap.
  private func applyWrappedContentSize(_ contentWidth: CGFloat) {
    let size = CGSize(width: contentWidth, height: ceil(layout.totalHeight))
    if frame.size != size {
      setFrameSize(size)
    }
  }

  /// Run any deferred re-wrap immediately at the settled width. Invoked by the
  /// coalescing timer and on teardown so a pending pass never strands stale
  /// wrapping on screen.
  @objc func flushPendingWrapLayout() {
    cancelPendingWrapLayout()
    guard let viewportWidth = pendingWrapViewportWidth else { return }
    pendingWrapViewportWidth = nil
    resizeForViewportWidth(viewportWidth)
  }

  /// (Re)arm the coalescing timer for a deferred re-wrap. Each resize frame
  /// cancels the previous arming, so the flush only fires once the width holds
  /// still for `wrapLayoutCoalesceDelay`.
  func schedulePendingWrapLayout() {
    cancelPendingWrapLayout()
    perform(
      #selector(flushPendingWrapLayout),
      with: nil,
      afterDelay: Self.wrapLayoutCoalesceDelay,
      inModes: [.common]
    )
  }

  func cancelPendingWrapLayout() {
    NSObject.cancelPreviousPerformRequests(
      withTarget: self,
      selector: #selector(flushPendingWrapLayout),
      object: nil
    )
  }

  func rebuildWrappedRowLayouts(contentWidth: CGFloat) {
    // A resize tick with an unchanged width (the common SwiftUI re-invocation
    // from selection, hover, or thread updates) reuses the existing layouts.
    if contentWidth == lastWrappedContentWidth, wrappedRowLayouts.count == rows.count {
      return
    }
    // Bound the cross-width cache so a drag-resize across many widths cannot
    // grow it without limit; `wrappedRowLayouts` always holds the current width.
    if wrappedRowCache.count > rows.count * 2 + 128 {
      wrappedRowCache.removeAll(keepingCapacity: true)
    }
    wrappedRowLayouts = rows.map { row in
      let key = WrapKey(
        rowID: row.id,
        characterLimit: characterLimit(for: row, contentWidth: contentWidth),
        softWrapEnabled: softWrapEnabled
      )
      if let cached = wrappedRowCache[key] {
        return cached
      }
      let layout = DashboardReviewFileDiffWrapLayout.layout(
        row: row,
        language: codeLanguage,
        softWrapEnabled: softWrapEnabled,
        characterLimit: key.characterLimit
      )
      wrappedRowCache[key] = layout
      wrapLayoutComputeCount += 1
      return layout
    }
    lastWrappedContentWidth = contentWidth
  }

  func characterLimit(
    for row: DashboardReviewFileDiffRow,
    contentWidth: CGFloat
  ) -> Int {
    let availableWidth: CGFloat =
      switch row.kind {
      case .addition, .context, .deletion:
        codeColumnWidth(contentWidth: contentWidth)
      case .contextGap, .hunk, .metadata:
        max(contentWidth - 24, characterWidth)
      }
    return max(Int(floor(availableWidth / characterWidth)), 1)
  }

  func codeColumnWidth(contentWidth: CGFloat) -> CGFloat {
    switch viewMode {
    case .unified:
      DashboardReviewFileDiffGridGeometry.unifiedCodeColumnWidth(
        contentWidth: contentWidth, characterWidth: characterWidth)
    case .split:
      DashboardReviewFileDiffGridGeometry.splitCodeColumnWidth(
        columnWidth: floor((contentWidth - 1) / 2), characterWidth: characterWidth)
    }
  }
}
