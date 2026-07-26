import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness code highlight attributed string")
struct HarnessCodeHighlightAttributedStringTests {
  @Test(
    "merged-run coloring matches per-span coloring across the benchmark corpus",
    arguments: HarnessCodeHighlightBenchmarkCorpus.latencyCases
  )
  func mergedRunColoringMatchesPerSpanColoring(sample: HarnessCodeHighlightLatencyCase) {
    let highlights = HarnessCodeHighlighter.highlightsUncached(
      sample.source,
      language: sample.language
    )

    let rendered = HarnessCodeHighlighter.makeAttributedString(from: highlights)

    #expect(String(rendered.characters) == sample.source)
    #expect(rendered == coloringEachSpan(in: highlights))
  }

  @Test("multi-byte source keeps its characters and colors")
  func multiByteSourceKeepsCharactersAndColors() {
    let source = "let emoji = \"🇵🇱 ✅ é\"\n// zażółć gęślą jaźń\n"
    let highlights = HarnessCodeHighlighter.highlightsUncached(source, language: .swift)

    let rendered = HarnessCodeHighlighter.makeAttributedString(from: highlights)

    #expect(String(rendered.characters) == source)
    #expect(rendered == coloringEachSpan(in: highlights))
  }

  @Test("spans that leave a gap fall back to per-span coloring")
  func spansThatLeaveAGapFallBackToPerSpanColoring() {
    let source = "alpha beta gamma"
    let start = source.startIndex
    let highlights = HarnessCodeHighlights(
      source: source,
      spans: [
        .init(range: start..<source.index(start, offsetBy: 5), kind: .keyword),
        .init(
          range: source.index(start, offsetBy: 6)..<source.index(start, offsetBy: 10),
          kind: .string
        ),
      ]
    )

    let rendered = HarnessCodeHighlighter.makeAttributedString(from: highlights)

    #expect(String(rendered.characters) == source)
    #expect(rendered == coloringEachSpan(in: highlights))
    // The gap and the trailing text claim no span, so they must stay uncolored
    // rather than inherit whichever kind the fast path would have used as base.
    #expect(rendered.runs.contains { $0.foregroundColor == nil })
  }

  @Test("an empty source renders an empty string")
  func emptySourceRendersEmptyString() {
    let rendered = HarnessCodeHighlighter.makeAttributedString(from: .empty)

    #expect(String(rendered.characters).isEmpty)
  }

  @Test("source past the last span still reaches the output")
  func sourcePastTheLastSpanStillReachesTheOutput() {
    let source = "alpha beta gamma"
    let firstWord = source.startIndex..<source.firstIndex(of: " ")!
    let highlights = HarnessCodeHighlights(
      source: source,
      spans: [.init(range: firstWord, kind: .keyword)]
    )

    let rendered = HarnessCodeHighlighter.makeAttributedString(from: highlights)

    #expect(String(rendered.characters) == source)
  }

  /// The color-each-span build the merged-run path replaced, kept as reference.
  private func coloringEachSpan(
    in highlights: HarnessCodeHighlights,
    colors: HarnessCodeTokenColors = .default
  ) -> AttributedString {
    var rendered = AttributedString(highlights.source)
    for span in highlights.spans {
      guard
        let lower = AttributedString.Index(span.range.lowerBound, within: rendered),
        let upper = AttributedString.Index(span.range.upperBound, within: rendered)
      else {
        continue
      }
      rendered[lower..<upper].foregroundColor = colors.color(for: span.kind)
    }
    return rendered
  }
}
