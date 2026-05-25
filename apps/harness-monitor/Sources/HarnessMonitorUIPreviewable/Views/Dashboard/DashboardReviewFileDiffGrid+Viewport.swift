import AppKit
import HarnessMonitorKit

@MainActor
extension DashboardReviewFileDiffGridContentView {
  func firstThreadURL(forRowID rowID: Int) -> String? {
    threadsByRowID[rowID]?.first(where: { $0.url != nil })?.url
  }

  func preferredViewportHeight() -> CGFloat {
    min(max(layout.totalHeight, 84), 720)
  }

  func wrappedLayout(for rowID: Int) -> DashboardReviewFileDiffWrappedRowLayout? {
    guard let index = rowIndexByID[rowID], wrappedRowLayouts.indices.contains(index) else {
      return nil
    }
    return wrappedRowLayouts[index]
  }

  func notifyPreferredViewportHeightChanged() {
    guard let onPreferredViewportHeightChange else { return }
    let measuredHeight = preferredViewportHeight()
    DispatchQueue.main.async {
      onPreferredViewportHeightChange(measuredHeight)
    }
  }
}
