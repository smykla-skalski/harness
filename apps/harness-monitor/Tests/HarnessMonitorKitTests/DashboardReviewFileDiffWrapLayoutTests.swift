import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file diff wrap layout")
struct DashboardReviewFileDiffWrapLayoutTests {
  @Test("soft wrap keeps source rows single-line when disabled")
  func wrapDisabledKeepsSingleLine() {
    let row = sourceRow(
      text: "func render(alpha: Alpha, beta: Beta, gamma: Gamma, delta: Delta)"
    )

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .swift,
      softWrapEnabled: false,
      characterLimit: 24
    )

    #expect(layout.lineCount == 1)
    #expect(layout.displayText == row.text)
  }

  @Test("soft wrap breaks Swift argument lists at commas with a fixed continuation indent")
  func swiftArgumentsUseFixedContinuationIndent() {
    let row = sourceRow(
      text: "func render(alpha: Alpha, beta: Beta, gamma: Gamma, delta: Delta)"
    )

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .swift,
      softWrapEnabled: true,
      characterLimit: 28
    )

    #expect(layout.lineCount > 1)
    #expect(layout.displayText.contains("Alpha,\n  beta"))
  }

  @Test("metadata rows wrap on whitespace instead of forcing hard mid-word breaks")
  func metadataRowsWrapOnWhitespace() {
    let row = DashboardReviewFileDiffRow(
      id: 0,
      kind: .metadata,
      oldLine: nil,
      newLine: nil,
      diffPosition: nil,
      text: "rename from Sources/VeryLongOldPath/FileName.swift",
      contextGap: nil
    )

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .generic,
      softWrapEnabled: true,
      characterLimit: 20
    )

    #expect(layout.lineCount > 1)
    #expect(layout.displayText.contains("rename from\n"))
  }

  @Test("wrapped code comments break on whitespace instead of inside words")
  func codeCommentsPreferWordBoundaries() {
    let row = sourceRow(
      text: "// one two three four five six seven eight nine ten"
    )

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .go,
      softWrapEnabled: true,
      characterLimit: 18
    )

    #expect(layout.lineCount > 1)
    #expect(layout.displayLines.first == "// one two three")
    #expect(layout.displayLines.dropFirst().first == "  four five six")
  }

  @Test("string literal rows search forward for a safer boundary before wrapping")
  func stringsPreferBoundaryAfterClosingDelimiter() {
    let row = sourceRow(
      text: #"It("should return resource exhausted while registration", func() {"#
    )

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .go,
      softWrapEnabled: true,
      characterLimit: 44
    )

    #expect(layout.lineCount > 1)
    #expect(layout.displayText.contains("registration\",\n  func() {"))
  }

  private func sourceRow(text: String) -> DashboardReviewFileDiffRow {
    DashboardReviewFileDiffRow(
      id: 0,
      kind: .addition,
      oldLine: nil,
      newLine: 1,
      diffPosition: 1,
      text: text,
      contextGap: nil
    )
  }
}
