import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffLatencySample: Equatable {
  let sizeName: String
  let lineCount: Int
  let rowCount: Int
  let parseMilliseconds: Double
  let visibleHighlightMilliseconds: Double
}

enum DashboardReviewFileDiffPerformanceProbe {
  static func measure(
    sizeName: String,
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    visibleRowLimit: Int = 160
  ) -> DashboardReviewFileDiffLatencySample {
    let lineCount = patch.patch.isEmpty ? 0 : patch.patch.split(separator: "\n").count
    let parseInterval = ReviewFilesPerf.beginLatencyProof(size: sizeName, lineCount: lineCount)
    let parseStart = DispatchTime.now().uptimeNanoseconds
    let document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    let parseElapsed = elapsedMilliseconds(since: parseStart)
    ReviewFilesPerf.end(parseInterval)

    let visibleRows = document.rows
      .filter { !$0.copyText.isEmpty }
      .prefix(visibleRowLimit)
    let highlightInterval = ReviewFilesPerf.beginVisibleHighlight(
      size: sizeName,
      rowCount: visibleRows.count
    )
    let highlightStart = DispatchTime.now().uptimeNanoseconds
    let codeLanguage = HarnessCodeLanguage(reviewLanguage: language)
    for row in visibleRows {
      _ = HarnessCodeHighlighter.highlight(row.text, language: codeLanguage)
    }
    let highlightElapsed = elapsedMilliseconds(since: highlightStart)
    ReviewFilesPerf.end(highlightInterval)

    return DashboardReviewFileDiffLatencySample(
      sizeName: sizeName,
      lineCount: lineCount,
      rowCount: document.rows.count,
      parseMilliseconds: parseElapsed,
      visibleHighlightMilliseconds: highlightElapsed
    )
  }

  private static func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}
