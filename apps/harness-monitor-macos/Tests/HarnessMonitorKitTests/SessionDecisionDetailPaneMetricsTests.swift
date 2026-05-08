import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session decision detail pane metrics")
struct SessionDecisionDetailPaneMetricsTests {
  @Test("Default font scale keeps detail pane padding stable")
  func defaultFontScaleKeepsDetailPanePaddingStable() {
    let metrics = SessionDecisionDetailPaneMetrics(fontScale: 1.0)

    #expect(metrics.contentPadding == 24)
  }

  @Test("Large font scale expands detail pane padding")
  func largeFontScaleExpandsDetailPanePadding() {
    let defaultMetrics = SessionDecisionDetailPaneMetrics(fontScale: 1.0)
    let largeMetrics = SessionDecisionDetailPaneMetrics(fontScale: 1.8)

    #expect(largeMetrics.contentPadding > defaultMetrics.contentPadding)
  }

  @Test("Detail pane metrics clamp extreme font scales")
  func detailPaneMetricsClampExtremeFontScales() {
    #expect(
      SessionDecisionDetailPaneMetrics(fontScale: 0.1)
        == SessionDecisionDetailPaneMetrics(fontScale: 0.85)
    )
    #expect(
      SessionDecisionDetailPaneMetrics(fontScale: 9.0)
        == SessionDecisionDetailPaneMetrics(fontScale: 1.8)
    )
  }
}
