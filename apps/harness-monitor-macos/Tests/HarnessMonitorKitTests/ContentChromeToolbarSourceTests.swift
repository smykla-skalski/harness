import Foundation
import Testing

@Suite("Content chrome toolbar source contracts")
struct ContentChromeToolbarSourceTests {
  @Test("Refresh animation clock stays scoped to the symbol subtree")
  func refreshAnimationClockStaysScopedToSymbol() throws {
    let source = try sourceFile(at: "Views/App/ContentChromeToolbarSupport.swift")

    #expect(source.contains("var body: some View {\n    Button {"))
    #expect(!source.contains("var body: some View {\n    TimelineView"))
    #expect(source.contains("private var toolbarSymbol: some View {\n    TimelineView"))
  }

  private func sourceFile(at relativePath: String) throws -> String {
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
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
