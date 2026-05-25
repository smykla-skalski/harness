import AppKit

@MainActor
final class DashboardReviewFileDiffScrollView: NSScrollView {
  override var intrinsicContentSize: NSSize {
    guard let contentView = documentView as? DashboardReviewFileDiffGridContentView else {
      return super.intrinsicContentSize
    }
    return NSSize(width: NSView.noIntrinsicMetric, height: contentView.preferredViewportHeight())
  }

  override func layout() {
    super.layout()
    resizeDiffDocumentView()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    resizeDiffDocumentView()
  }

  private func resizeDiffDocumentView() {
    guard let contentView = documentView as? DashboardReviewFileDiffGridContentView else {
      return
    }
    // The per-frame `layout()` pass during a sidebar/window resize routes through
    // the coalescing entry so the document is not re-wrapped on every frame.
    contentView.relayoutForViewportResize(contentSize.width)
    invalidateIntrinsicContentSize()
  }
}
