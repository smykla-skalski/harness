import Foundation
import Testing

@Suite("Content chrome toolbar source contracts")
struct ContentChromeToolbarSourceTests {
  @Test("Refresh animation clock stays scoped to the symbol subtree")
  func refreshAnimationClockStaysScopedToSymbol() throws {
    let source = try sourceFile(at: "Views/App/ContentChromeToolbarSupport.swift")

    #expect(source.contains("var body: some View {\n    Button {"))
    #expect(!source.contains("TimelineView"))
    #expect(source.contains(".symbolEffect(.rotate, options: .repeating, isActive: shouldSpin)"))
    #expect(!source.contains("paused:"))
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
