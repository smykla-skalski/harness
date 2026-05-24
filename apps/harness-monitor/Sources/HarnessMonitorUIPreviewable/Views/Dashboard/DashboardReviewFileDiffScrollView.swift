import AppKit

@MainActor
final class DashboardReviewFileDiffScrollView: NSScrollView {
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
    contentView.resizeForViewportWidth(contentSize.width)
  }
}
