import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff latency proofs")
struct DashboardReviewFileDiffLatencyProofTests {
  @Test(
    "source diff parse and visible highlighting stay under 100ms",
    arguments: [
      ("small", 40),
      ("medium", 360),
      ("large", 1_200),
    ]
  )
  func sourceDiffParseAndVisibleHighlightStayUnder100ms(
    sizeName: String,
    changedLines: Int
  ) {
    let sample = DashboardReviewFileDiffPerformanceProbe.measure(
      sizeName: sizeName,
      patch: patch(changedLines: changedLines),
      language: .swift
    )

    #expect(sample.lineCount >= changedLines)
    #expect(sample.parseMilliseconds < 100)
    #expect(sample.visibleHighlightMilliseconds < 100)
  }

  private func patch(changedLines: Int) -> ReviewFilePatch {
    var lines: [String] = [
      "diff --git a/Sources/Large.swift b/Sources/Large.swift",
      "index 1111111..2222222 100644",
      "--- a/Sources/Large.swift",
      "+++ b/Sources/Large.swift",
      "@@ -1,\(changedLines) +1,\(changedLines) @@",
    ]
    for index in 0..<changedLines {
      if index.isMultiple(of: 5) {
        lines.append("-let value\(index) = \(index)")
        lines.append("+let value\(index) = \(index + 1)")
      } else {
        lines.append(" let value\(index) = \(index)")
      }
    }
    return ReviewFilePatch(
      path: "Sources/Large.swift",
      patch: lines.joined(separator: "\n"),
      status: .modified,
      additions: UInt32(changedLines / 5),
      deletions: UInt32(changedLines / 5),
      fetchedAt: "2026-05-23T12:00:00Z",
      headRefOid: "head-latency"
    )
  }
}
