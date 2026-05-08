import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window route content metrics")
struct SessionWindowRouteContentMetricsTests {
  @Test("Metrics scale overview and row chrome")
  func metricsScaleOverviewAndRowChrome() {
    let regular = SessionWindowRouteContentMetrics(fontScale: 1.0)
    let large = SessionWindowRouteContentMetrics(fontScale: 1.8)

    #expect(large.contentPadding > regular.contentPadding)
    #expect(large.overviewSpacing > regular.overviewSpacing)
    #expect(large.gridHorizontalSpacing > regular.gridHorizontalSpacing)
    #expect(large.gridVerticalSpacing > regular.gridVerticalSpacing)
    #expect(large.rowTextSpacing > regular.rowTextSpacing)
  }

  @Test("Metrics clamp extreme font scales")
  func metricsClampExtremeFontScales() {
    #expect(
      SessionWindowRouteContentMetrics(fontScale: 0.1)
        == SessionWindowRouteContentMetrics(fontScale: 0.85)
    )
    #expect(
      SessionWindowRouteContentMetrics(fontScale: 9.0)
        == SessionWindowRouteContentMetrics(fontScale: 1.8)
    )
  }

  @Test("Task detail pane metrics scale and clamp with the session font scale")
  func taskDetailPaneMetricsScaleAndClampWithSessionFontScale() {
    let regular = SessionTaskDetailPaneMetrics(fontScale: 1.0)
    let large = SessionTaskDetailPaneMetrics(fontScale: 1.8)

    #expect(large.contentPadding > regular.contentPadding)
    #expect(
      SessionTaskDetailPaneMetrics(fontScale: 0.1)
        == SessionTaskDetailPaneMetrics(fontScale: 0.85)
    )
    #expect(
      SessionTaskDetailPaneMetrics(fontScale: 9.0)
        == SessionTaskDetailPaneMetrics(fontScale: 1.8)
    )
  }

  @Test("Task selection renders a real detail pane")
  func taskSelectionRendersARealDetailPane() throws {
    let columnsSource = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(columnsSource.contains("SessionTaskDetailPane("))
    #expect(!columnsSource.contains("Task detail lands in a later chunk."))
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
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views/Sessions")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
