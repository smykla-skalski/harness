import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window create form metrics")
struct SessionWindowCreateFormMetricsTests {
  @Test("Metrics scale form padding and preserve large submit hit target")
  func metricsScaleFormPaddingAndPreserveLargeHitTarget() {
    let regular = SessionWindowCreateFormMetrics(fontScale: 1.0)
    let large = SessionWindowCreateFormMetrics(fontScale: 1.8)

    #expect(large.formPadding > regular.formPadding)
    #expect(large.promptMinHeight > regular.promptMinHeight)
    #expect(large.submitButtonMinHeight == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 0.1)
        == SessionWindowCreateFormMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowCreateFormMetrics(fontScale: 9.0)
        == SessionWindowCreateFormMetrics(fontScale: 1.8)
    )
  }
}
