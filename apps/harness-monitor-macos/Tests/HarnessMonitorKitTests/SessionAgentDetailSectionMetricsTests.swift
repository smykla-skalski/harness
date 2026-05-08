import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session agent detail metrics")
struct SessionAgentDetailSectionMetricsTests {
  @Test("Metrics scale TUI and composer chrome")
  func metricsScaleTUIAndComposerChrome() {
    let regular = SessionAgentDetailSectionMetrics(fontScale: 1.0)
    let large = SessionAgentDetailSectionMetrics(fontScale: 1.8)

    #expect(large.sectionSpacing > regular.sectionSpacing)
    #expect(large.sectionPadding > regular.sectionPadding)
    #expect(large.terminalPadding > regular.terminalPadding)
    #expect(large.composerSpacing > regular.composerSpacing)
    #expect(large.keyButtonWidth > regular.keyButtonWidth)
    #expect(large.composerMinHeight > regular.composerMinHeight)
    #expect(large.controlButtonMinSize == 44)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionAgentDetailSectionMetrics(fontScale: 0.1)
        == SessionAgentDetailSectionMetrics(fontScale: 0.85)
    )
    #expect(
      SessionAgentDetailSectionMetrics(fontScale: 9.0)
        == SessionAgentDetailSectionMetrics(fontScale: 1.8)
    )
  }
}
