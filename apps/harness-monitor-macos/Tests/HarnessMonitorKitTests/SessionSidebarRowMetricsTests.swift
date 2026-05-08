import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session sidebar row metrics")
struct SessionSidebarRowMetricsTests {
  @Test("Default font scale keeps sidebar rows compact")
  func defaultFontScaleKeepsRowsCompact() {
    let metrics = SessionSidebarRowMetrics(fontScale: 1.0)

    #expect(metrics.minHeight == 28)
    #expect(metrics.multiSelectControlSize == 24)
    #expect(metrics.dragHandleColumnWidth == 12)
    #expect(metrics.dragHandleHitTarget == 24)
    #expect(metrics.severityIndicatorSize == 8)
  }

  @Test("Large font scale preserves effective hit targets")
  func largeFontScalePreservesEffectiveHitTargets() {
    let metrics = SessionSidebarRowMetrics(fontScale: 1.8)

    #expect(metrics.minHeight >= 44)
    #expect(metrics.multiSelectControlSize >= 44)
    #expect(metrics.dragHandleHitTarget >= 44)
    #expect(
      metrics.iconColumnWidth
        > SessionSidebarRowMetrics(fontScale: 1.0).iconColumnWidth
    )
    #expect(
      metrics.severityIndicatorSize
        > SessionSidebarRowMetrics(fontScale: 1.0).severityIndicatorSize
    )
  }

  @Test("Font scale clamps extreme values")
  func fontScaleClampsExtremeValues() {
    #expect(
      SessionSidebarRowMetrics(fontScale: 0.1)
        == SessionSidebarRowMetrics(fontScale: 0.85)
    )
    #expect(
      SessionSidebarRowMetrics(fontScale: 9.0)
        == SessionSidebarRowMetrics(fontScale: 1.8)
    )
  }
}
