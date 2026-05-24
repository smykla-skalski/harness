import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window create form codex source")
struct SessionWindowCreateFormCodexSourceTests {
  @Test("Codex form uses a static model label")
  func codexFormUsesStaticModelLabel() throws {
    let source = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowCreateForm+Helpers.swift")
    let staticModelPickerSource = [
      "Picker(",
      "          \"Model\",",
      "          selection: codexModelPickerSelection",
    ].joined(separator: "\n")

    #expect(source.contains(staticModelPickerSource))
    #expect(!source.contains("selectedCodexModelMenuTitle(catalog: codexCatalog)"))
    #expect(!source.contains("func selectedCodexModelMenuTitle"))
  }

  private func previewableSourceFile(at relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
