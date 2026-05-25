import Foundation
import HarnessMonitorKit

struct DashboardReviewFileDiffLatencySample: Equatable {
  let sizeName: String
  let lineCount: Int
  let rowCount: Int
  let parseMilliseconds: Double
  let visibleHighlightMilliseconds: Double
  let wrapLayoutMilliseconds: Double
}

enum DashboardReviewFileDiffPerformanceProbe {
  @MainActor
  static func measure(
    sizeName: String,
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    visibleRowLimit: Int = 160,
    measureWrapLayout: Bool = false,
    viewportWidth: CGFloat = 960
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
      _ = HarnessCodeHighlighter.highlightsUncached(row.text, language: codeLanguage)
    }
    let highlightElapsed = elapsedMilliseconds(since: highlightStart)
    ReviewFilesPerf.end(highlightInterval)

    let wrapElapsed: Double
    if measureWrapLayout {
      let wrapInterval = ReviewFilesPerf.beginWrapLayout(
        size: sizeName,
        rowCount: document.rows.count,
        viewportWidth: Int(viewportWidth.rounded())
      )
      let wrapStart = DispatchTime.now().uptimeNanoseconds
      let contentView = DashboardReviewFileDiffGridContentView()
      contentView.configure(
        document: document,
        viewMode: .unified,
        fontScale: 1,
        softWrapEnabled: true,
        threads: [],
        repositoryFullName: nil,
        conversationThreads: [],
        conversationVisibility: .all,
        viewerLogin: nil,
        loadAvatar: nil,
        onResolveToggle: nil,
        onReply: nil,
        onPreferredViewportHeightChange: nil,
        pullRequestID: "",
        lineSelection: nil,
        onSelectLines: nil
      )
      contentView.resizeForViewportWidth(viewportWidth)
      wrapElapsed = elapsedMilliseconds(since: wrapStart)
      ReviewFilesPerf.end(wrapInterval)
    } else {
      wrapElapsed = 0
    }

    return DashboardReviewFileDiffLatencySample(
      sizeName: sizeName,
      lineCount: lineCount,
      rowCount: document.rows.count,
      parseMilliseconds: parseElapsed,
      visibleHighlightMilliseconds: highlightElapsed,
      wrapLayoutMilliseconds: wrapElapsed
    )
  }

  private static func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}
