import Foundation
import Testing

@Suite("Feedback toast source contracts")
struct FeedbackToastSourceContractTests {
  @Test("Details keep duplicate rows off self identity")
  func feedbackToastDetailsKeepEnumeratedRowIdentity() throws {
    let source = try sourceFile(at: "Views/Shared/HarnessMonitorFeedbackToastView.swift")

    #expect(source.contains("ForEach(Array(details.rows.enumerated()), id: \\.offset)"))
    #expect(!source.contains("ForEach(details.rows.indices, id: \\.self)"))
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
