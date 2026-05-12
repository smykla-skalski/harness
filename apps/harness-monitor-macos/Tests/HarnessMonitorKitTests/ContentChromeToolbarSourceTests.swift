import Foundation
import Testing

@Suite("Content chrome toolbar source contracts")
struct ContentChromeToolbarSourceTests {
  @Test("Refresh startup state stays on the static symbol path")
  func refreshStartupStateStaysOnStaticSymbolPath() throws {
    let source = try sourceFile(at: "Views/App/ContentChromeToolbarSupport.swift")

    #expect(source.contains("private var refreshButton: some View"))
    #expect(source.contains("Button {\n      Task { await store.manualRefresh() }"))
    #expect(!source.contains("TimelineView"))
    #expect(!source.contains("shouldSpin"))
    #expect(!source.contains(".symbolEffect(.rotate"))
    #expect(source.contains("!reduceMotion && (showsSuccessFeedback || showsSuccessTint)"))
    #expect(source.contains(".contentTransition("))
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
