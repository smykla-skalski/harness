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
  @MainActor
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

  @Test(
    "wrapped diff layout stays under 100ms for long lines",
    arguments: [
      ("medium-wrap", 240),
      ("large-wrap", 720),
    ]
  )
  @MainActor
  func wrappedDiffLayoutStaysUnder100ms(
    sizeName: String,
    changedLines: Int
  ) {
    let sample = DashboardReviewFileDiffPerformanceProbe.measure(
      sizeName: sizeName,
      patch: wrapHeavyPatch(changedLines: changedLines),
      language: .swift,
      measureWrapLayout: true,
      viewportWidth: 920
    )

    #expect(sample.rowCount >= changedLines)
    #expect(sample.wrapLayoutMilliseconds < 100)
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

  private func wrapHeavyPatch(changedLines: Int) -> ReviewFilePatch {
    var lines: [String] = [
      "diff --git a/Sources/WrapHeavy.swift b/Sources/WrapHeavy.swift",
      "index 3333333..4444444 100644",
      "--- a/Sources/WrapHeavy.swift",
      "+++ b/Sources/WrapHeavy.swift",
      "@@ -1,\(changedLines) +1,\(changedLines) @@",
    ]
    for index in 0..<changedLines {
      let line =
        " let wrappedValue\(index) = runTask("
        + "alpha: input.alpha\(index), "
        + "beta: transform(beta: input.beta\(index), gamma: input.gamma\(index)), "
        + "delta: computeDelta(lhs: previousDelta\(index),"
        + " rhs: nextDelta\(index), fallback: defaultDelta\(index)))"
      lines.append(line)
    }
    return ReviewFilePatch(
      path: "Sources/WrapHeavy.swift",
      patch: lines.joined(separator: "\n"),
      status: .modified,
      additions: UInt32(changedLines),
      deletions: 0,
      fetchedAt: "2026-05-25T12:00:00Z",
      headRefOid: "head-wrap-latency"
    )
  }
}
