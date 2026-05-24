import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session filtered decision notice")
struct SessionFilteredDecisionNoticeTests {
  @Test("Metrics scale notice chrome and preserve large clear button hit target")
  func metricsScaleNoticeChromeAndPreserveLargeHitTarget() {
    let regular = SessionFilteredDecisionNoticeMetrics(fontScale: 1.0)
    let large = SessionFilteredDecisionNoticeMetrics(fontScale: 1.8)

    #expect(large.spacing > regular.spacing)
    #expect(large.textSpacing > regular.textSpacing)
    #expect(large.padding > regular.padding)
    #expect(large.cornerRadius > regular.cornerRadius)
    #expect(large.clearButtonMinHeight == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionFilteredDecisionNoticeMetrics(fontScale: 0.1)
        == SessionFilteredDecisionNoticeMetrics(fontScale: 0.85)
    )
    #expect(
      SessionFilteredDecisionNoticeMetrics(fontScale: 9.0)
        == SessionFilteredDecisionNoticeMetrics(fontScale: 1.8)
    )
  }
}
