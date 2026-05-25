import Foundation
import HarnessMonitorKit

struct HarnessCodeHighlightLatencySample: Equatable {
  let surface: String
  let language: HarnessCodeLanguage
  let byteCount: Int
  let spanCount: Int
  let highlightMilliseconds: Double
  let renderMilliseconds: Double
}

enum HarnessCodeHighlightPerformanceProbe {
  static func measure(
    surface: String,
    source: String,
    language: HarnessCodeLanguage,
    colors: HarnessCodeTokenColors = .default
  ) -> HarnessCodeHighlightLatencySample {
    let highlightInterval = ReviewFilesPerf.beginSharedHighlight(
      surface: surface,
      language: language.rawValue,
      byteCount: source.utf8.count
    )
    let highlightStart = DispatchTime.now().uptimeNanoseconds
    let highlights = HarnessCodeHighlighter.highlightsUncached(source, language: language)
    let highlightElapsed = elapsedMilliseconds(since: highlightStart)
    ReviewFilesPerf.end(highlightInterval)

    let renderInterval = ReviewFilesPerf.beginSharedRender(
      surface: surface,
      language: language.rawValue,
      spanCount: highlights.spans.count
    )
    let renderStart = DispatchTime.now().uptimeNanoseconds
    _ = HarnessCodeHighlighter.makeAttributedString(from: highlights, colors: colors)
    let renderElapsed = elapsedMilliseconds(since: renderStart)
    ReviewFilesPerf.end(renderInterval)

    return HarnessCodeHighlightLatencySample(
      surface: surface,
      language: language,
      byteCount: source.utf8.count,
      spanCount: highlights.spans.count,
      highlightMilliseconds: highlightElapsed,
      renderMilliseconds: renderElapsed
    )
  }

  private static func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }
}
