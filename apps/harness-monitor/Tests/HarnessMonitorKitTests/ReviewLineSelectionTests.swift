import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Review line selection")
struct ReviewLineSelectionTests {
  @Test("normalizes a reversed range so start <= end")
  func normalizesReversedRange() {
    let selection = ReviewLineSelection(start: 20, end: 10)
    #expect(selection.start == 10)
    #expect(selection.end == 20)
  }

  @Test("clamps line numbers below one up to one")
  func clampsBelowOne() {
    #expect(ReviewLineSelection(start: 0, end: 5).start == 1)
    #expect(ReviewLineSelection(start: -3, end: -1).start == 1)
    #expect(ReviewLineSelection(start: -3, end: -1).end == 1)
  }

  @Test("single-line initializer collapses start and end")
  func singleLineInit() {
    let selection = ReviewLineSelection(line: 42)
    #expect(selection.start == 42)
    #expect(selection.end == 42)
    #expect(selection.isSingleLine)
    #expect(selection.side == .right)
  }

  @Test("line count is inclusive")
  func inclusiveLineCount() {
    #expect(ReviewLineSelection(start: 10, end: 20).lineCount == 11)
    #expect(ReviewLineSelection(line: 7).lineCount == 1)
  }

  @Test("contains covers the inclusive bounds only")
  func containsBounds() {
    let selection = ReviewLineSelection(start: 10, end: 20)
    #expect(selection.contains(line: 10))
    #expect(selection.contains(line: 20))
    #expect(selection.contains(line: 15))
    #expect(!selection.contains(line: 9))
    #expect(!selection.contains(line: 21))
  }

  @Test("url lines value renders single and range forms")
  func urlLinesValue() {
    #expect(ReviewLineSelection(line: 42).urlLinesValue == "42")
    #expect(ReviewLineSelection(start: 10, end: 20).urlLinesValue == "10-20")
    // Reversed input still renders normalized.
    #expect(ReviewLineSelection(start: 20, end: 10).urlLinesValue == "10-20")
  }

  @Test("parse reads single line, range, and side")
  func parseValid() {
    let single = ReviewLineSelection.parse(linesQuery: "42", sideQuery: nil)
    #expect(single == ReviewLineSelection(line: 42, side: .right))

    let range = ReviewLineSelection.parse(linesQuery: "10-20", sideQuery: "left")
    #expect(range == ReviewLineSelection(start: 10, end: 20, side: .left))

    let rightExplicit = ReviewLineSelection.parse(linesQuery: "5", sideQuery: "right")
    #expect(rightExplicit?.side == .right)
  }

  @Test("parse defaults to the right side for missing or unknown side")
  func parseSideDefault() {
    #expect(ReviewLineSelection.parse(linesQuery: "5", sideQuery: nil)?.side == .right)
    #expect(ReviewLineSelection.parse(linesQuery: "5", sideQuery: "bogus")?.side == .right)
  }

  @Test("parse rejects malformed input")
  func parseRejectsMalformed() {
    #expect(ReviewLineSelection.parse(linesQuery: nil, sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "", sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "abc", sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "0", sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "10-", sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "-5", sideQuery: nil) == nil)
    #expect(ReviewLineSelection.parse(linesQuery: "10-20-30", sideQuery: nil) == nil)
  }

  @Test("codable round-trips through json")
  func codableRoundTrip() throws {
    let selection = ReviewLineSelection(start: 12, end: 34, side: .left)
    let data = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(ReviewLineSelection.self, from: data)
    #expect(decoded == selection)
  }
}
