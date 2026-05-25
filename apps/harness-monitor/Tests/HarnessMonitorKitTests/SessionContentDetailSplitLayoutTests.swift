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

  @Test("Narrow startup geometry clamps inside the available split width")
  func narrowStartupGeometryClampsInsideAvailableSplitWidth() {
    let availableWidth: CGFloat = 180
    let range = SessionContentDetailSplitLayout.contentWidthRange(
      availableWidth: availableWidth
    )
    let clampedWidth = SessionContentDetailSplitLayout.clampedContentWidth(
      preferredWidth: SessionContentDetailSplitLayout.defaultContentWidth,
      availableWidth: availableWidth
    )

    #expect(range.lowerBound == range.upperBound)
    #expect(clampedWidth == range.upperBound)
    #expect(
      (CGFloat(clampedWidth) * 2) + SessionContentDetailSplitLayout.dividerWidth
        <= availableWidth
    )
  }

  @MainActor
  @Test("Geometry writeback deferral waits until the next main-actor turn")
  func geometryWritebackDeferralWaitsUntilTheNextMainActorTurn() async {
    var events: [String] = []

    Task { @MainActor in
      events.append("scheduled")
      await SessionGeometryWritebackDeferral.nextMainActorTurn()
      events.append("ran")
    }

    #expect(events.isEmpty)
    await Task.yield()
    #expect(events == ["scheduled"])
    for _ in 0..<8 where events.count < 2 {
      await Task.yield()
    }
    #expect(events == ["scheduled", "ran"])
  }
}
