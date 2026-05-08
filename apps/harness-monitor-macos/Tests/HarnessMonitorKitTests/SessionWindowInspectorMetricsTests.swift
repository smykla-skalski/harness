import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window inspector metrics")
struct SessionWindowInspectorMetricsTests {
  @Test("Metrics scale pane chrome and preserve large close button hit target")
  func metricsScalePaneChromeAndPreserveLargeHitTarget() {
    let regular = SessionWindowInspectorMetrics(fontScale: 1.0)
    let large = SessionWindowInspectorMetrics(fontScale: 1.8)

    #expect(large.spacing > regular.spacing)
    #expect(large.padding > regular.padding)
    #expect(large.closeButtonMinSize == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowInspectorMetrics(fontScale: 0.1)
        == SessionWindowInspectorMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowInspectorMetrics(fontScale: 9.0)
        == SessionWindowInspectorMetrics(fontScale: 1.8)
    )
  }
}
