import SwiftUI
import Testing

@testable import HarnessMonitorKit
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

  @Test("Composer key layout covers every TUI key once")
  func composerKeyLayoutCoversEveryTUIKeyOnce() {
    #expect(Set(SessionAgentComposerKeyLayout.flattened) == Set(AgentTuiKey.allCases))
    #expect(SessionAgentComposerKeyLayout.flattened.count == AgentTuiKey.allCases.count)
  }

  @Test("Agent detail is split into viewport and composer views")
  func agentDetailIsSplitIntoViewportAndComposerViews() throws {
    let detailSource = try sourceFile(named: "SessionAgentDetailSection.swift")
    let laneSource = try sourceFile(named: "SessionAgentLaneViews.swift")
    let composerSource = try sourceFile(named: "SessionAgentComposer.swift")

    #expect(detailSource.contains("SessionAgentTuiViewport("))
    #expect(detailSource.contains("SessionAgentComposer("))
    #expect(laneSource.contains("accessibilityLabel(Text(latestOutput))"))
    #expect(composerSource.contains("GeometryReader"))
    #expect(composerSource.contains("SessionAgentComposerKeyLayout.rows"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
