import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session decision filter controls")
struct SessionDecisionFilterControlsTests {
  @Test("Metrics scale spacing and preserve large filter button hit target")
  func metricsScaleSpacingAndPreserveLargeHitTarget() {
    let regular = SessionDecisionFilterMetrics(fontScale: 1.0)
    let large = SessionDecisionFilterMetrics(fontScale: 1.8)

    #expect(large.verticalSpacing > regular.verticalSpacing)
    #expect(large.horizontalSpacing > regular.horizontalSpacing)
    #expect(large.filterButtonSize == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionDecisionFilterMetrics(fontScale: 0.1)
        == SessionDecisionFilterMetrics(fontScale: 0.85)
    )
    #expect(
      SessionDecisionFilterMetrics(fontScale: 9.0)
        == SessionDecisionFilterMetrics(fontScale: 1.8)
    )
  }
}
