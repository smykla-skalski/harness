import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session content-detail split layout")
struct SessionContentDetailSplitLayoutTests {
  @Test("Stored content width seeds native split ideal width")
  func storedContentWidthSeedsNativeSplitIdealWidth() {
    #expect(
      SessionContentDetailSplitLayout.preferredContentWidth(120)
        == SessionContentDetailSplitLayout.minimumContentWidth
    )
    #expect(
      SessionContentDetailSplitLayout.preferredContentWidth(520)
        == 520
    )
  }
}
