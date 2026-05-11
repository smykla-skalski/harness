import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session content-detail split layout")
struct SessionContentDetailSplitLayoutTests {
  @Test("Stored content width seeds native split ideal width")
  func storedContentWidthSeedsNativeSplitIdealWidth() {
    let range = SessionContentDetailSplitLayout.contentWidthRange(availableWidth: 820)

    #expect(
      SessionContentDetailSplitLayout.clampedContentWidth(
        preferredWidth: 120,
        availableWidth: 820
      )
        == range.lowerBound
    )
    #expect(
      SessionContentDetailSplitLayout.clampedContentWidth(
        preferredWidth: 520,
        availableWidth: 820
      )
        == range.upperBound
    )
  }

  @Test("Default content ideal fits the compact session window with detail")
  func defaultContentIdealFitsCompactSessionWindowWithDetail() {
    #expect(SessionContentDetailSplitLayout.defaultContentWidth == 440)
    #expect(SessionContentDetailSplitLayout.minimumContentWidth == 280)
    #expect(
      SessionContentDetailSplitLayout.contentWidthRange(availableWidth: 900)
        .contains(SessionContentDetailSplitLayout.defaultContentWidth)
    )
    #expect(
      SessionContentDetailSplitLayout.minimumContentWidth
        + SessionContentDetailSplitLayout.minimumDetailWidth
        <= 720
    )
  }
}
