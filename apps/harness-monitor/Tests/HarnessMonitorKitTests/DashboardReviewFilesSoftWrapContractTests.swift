import Foundation
import Testing

@Suite("Dashboard review files soft wrap contracts")
struct DashboardReviewFilesSoftWrapContractTests {
  @Test("Files settings expose a persisted soft-wrap default")
  func filesSettingsExposeSoftWrapToggle() throws {
    let source =
      try previewableSourceFile(named: "Views/Settings/SettingsReviewsFilesSection.swift")
    #expect(source.contains("Toggle(\"Soft wrap long lines\", isOn: $draft.filesSoftWrapEnabled)"))
    #expect(source.contains("settingsReviewFilesSoftWrapToggle"))
  }

  @Test("Files header exposes the in-view soft-wrap toggle")
  func filesHeaderExposesSoftWrapToggle() throws {
    let source =
      try previewableSourceFile(named: "Views/Dashboard/DashboardReviewFilesHeader.swift")
    #expect(source.contains("@Binding var softWrapEnabled"))
    #expect(source.contains("softWrapEnabled.toggle()"))
    #expect(source.contains("harnessFilterChipButtonStyle(isSelected: softWrapEnabled)"))
    #expect(source.contains("dashboardReviewFilesSoftWrapToggle"))
  }

  @Test(
    "Files detail pane exposes the in-view soft-wrap toggle and routes renders through the preference"
  )
  func filesDetailPaneExposesSoftWrapToggle() throws {
    let source =
      try previewableSourceFile(named: "Views/Dashboard/DashboardReviewFilesModeDetailPane.swift")
    #expect(source.contains("private var softWrapToggle"))
    #expect(source.contains("softWrapBinding.wrappedValue.toggle()"))
    #expect(
      source.contains("harnessFilterChipButtonStyle(isSelected: softWrapBinding.wrappedValue)"))
    #expect(source.contains("preferences.snapshot.filesSoftWrapEnabled"))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
