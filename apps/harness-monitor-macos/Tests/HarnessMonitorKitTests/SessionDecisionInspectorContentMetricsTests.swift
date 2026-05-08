import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session decision inspector content metrics")
struct SessionDecisionInspectorContentMetricsTests {
  @Test("Default font scale keeps inspector rows compact")
  func defaultFontScaleKeepsInspectorRowsCompact() {
    let metrics = SessionDecisionInspectorContentMetrics(fontScale: 1.0)

    #expect(metrics.sectionSpacing == 12)
    #expect(metrics.rowSpacing == 8)
    #expect(metrics.historyTitleSpacing == 2)
  }

  @Test("Large font scale expands inspector row spacing")
  func largeFontScaleExpandsInspectorRowSpacing() {
    let defaultMetrics = SessionDecisionInspectorContentMetrics(fontScale: 1.0)
    let largeMetrics = SessionDecisionInspectorContentMetrics(fontScale: 1.8)

    #expect(largeMetrics.sectionSpacing > defaultMetrics.sectionSpacing)
    #expect(largeMetrics.rowSpacing > defaultMetrics.rowSpacing)
    #expect(largeMetrics.historyTitleSpacing > defaultMetrics.historyTitleSpacing)
  }

  @Test("Inspector metrics clamp extreme font scales")
  func inspectorMetricsClampExtremeFontScales() {
    #expect(
      SessionDecisionInspectorContentMetrics(fontScale: 0.1)
        == SessionDecisionInspectorContentMetrics(fontScale: 0.85)
    )
    #expect(
      SessionDecisionInspectorContentMetrics(fontScale: 9.0)
        == SessionDecisionInspectorContentMetrics(fontScale: 1.8)
    )
  }
}
