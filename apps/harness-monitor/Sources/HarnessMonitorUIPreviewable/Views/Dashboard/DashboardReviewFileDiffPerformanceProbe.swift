import AppKit
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

/// Per-frame draw cost while scrolling a diff, sampled off-screen. `cold` is the
/// first pass over each viewport (Core Text line layouts not yet cached, the
/// worst case when scrolling into new rows); `warm` is a re-scroll over the same
/// rows (cache hits, the steady-state cost).
struct DashboardReviewFileDiffDrawScrollSample: Equatable {
  let frameCount: Int
  let coldMedianMilliseconds: Double
  let coldMaxMilliseconds: Double
  let warmMedianMilliseconds: Double
  let warmMaxMilliseconds: Double
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
        deepLinkID: "",
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

  /// Drive the real content view's draw path off-screen while scrolling a
  /// viewport down the document, timing each frame. Exercises the per-line draw
  /// hot path (`semanticCodeLineCache` lookup, gstate setup, `CTLineDraw`).
  @MainActor
  static func measureDrawScroll(
    patch: ReviewFilePatch,
    language: HarnessReviewFileLanguage,
    viewMode: FilesViewMode = .split,
    viewportWidth: CGFloat = 920,
    viewportHeight: CGFloat = 600,
    frames: Int = 32
  ) -> DashboardReviewFileDiffDrawScrollSample {
    let document = DashboardReviewFileDiffDocument(patch: patch, language: language)
    let view = DashboardReviewFileDiffGridContentView()
    view.configure(
      document: document,
      viewMode: viewMode,
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
      deepLinkID: "",
      lineSelection: nil,
      onSelectLines: nil
    )
    view.resizeForViewportWidth(viewportWidth)
    let viewport = NSRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: viewport) else {
      return DashboardReviewFileDiffDrawScrollSample(
        frameCount: 0,
        coldMedianMilliseconds: 0,
        coldMaxMilliseconds: 0,
        warmMedianMilliseconds: 0,
        warmMaxMilliseconds: 0
      )
    }
    let maxOffset = max(view.frame.height - viewportHeight, 0)
    let step = frames > 1 ? maxOffset / CGFloat(frames - 1) : 0
    func scrollPass() -> [Double] {
      (0..<frames).map { index in
        let rect = NSRect(
          x: 0,
          y: CGFloat(index) * step,
          width: viewportWidth,
          height: viewportHeight
        )
        let start = DispatchTime.now().uptimeNanoseconds
        view.cacheDisplay(in: rect, to: rep)
        return elapsedMilliseconds(since: start)
      }
    }
    let cold = scrollPass()
    let warm = scrollPass()
    return DashboardReviewFileDiffDrawScrollSample(
      frameCount: frames,
      coldMedianMilliseconds: median(cold),
      coldMaxMilliseconds: cold.max() ?? 0,
      warmMedianMilliseconds: median(warm),
      warmMaxMilliseconds: warm.max() ?? 0
    )
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  private static func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}
