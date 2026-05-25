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

    // The closing-delimiter boundary sits ~57 columns in; a 60-column budget
    // keeps it in-budget so we break there without spilling past the column.
    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .go,
      softWrapEnabled: true,
      characterLimit: 60
    )

    #expect(layout.lineCount > 1)
    #expect(layout.displayText.contains("registration\",\n  func() {"))
  }

  @Test("indented prose string rows wrap at word boundaries instead of exploding")
  func indentedProseStringsStayReadable() {
    let helpRow = sourceRow(text: "Help:")
    let proseRow = sourceRow(
      text: #"        "Distribution of resource counts per xDS snapshot by resource type.","#
    )

    let helpLayout = DashboardReviewFileDiffWrapLayout.layout(
      row: helpRow,
      language: .go,
      softWrapEnabled: true,
      characterLimit: 18
    )
    let proseLayout = DashboardReviewFileDiffWrapLayout.layout(
      row: proseRow,
      language: .go,
      softWrapEnabled: true,
      characterLimit: 24
    )

    let visibleLines = proseLayout.displayLines.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #expect(helpLayout.lineCount == 1)
    #expect(proseLayout.lineCount > 1)
    #expect(!visibleLines.contains("\""))
    #expect(!visibleLines.contains(where: { $0.count == 1 }))
    #expect(visibleLines.first?.hasPrefix("\"Distribution") == true)
    #expect(visibleLines.dropFirst().contains(where: { $0.contains(" ") }))
    #expect(proseLayout.displayLines.allSatisfy { $0.count <= 24 })
  }

  @Test("wrapped code lines never exceed the column budget")
  func wrappedLinesNeverExceedBudget() {
    let samples = [
      // gofmt-aligned struct field (the screenshot case), space-aligned.
      "XdsStreamRegistrationInProgressRetries          *prometheus.CounterVec",
      "func render(alpha: Alpha, beta: Beta, gamma: Gamma, delta: Delta) -> Out",
      #"let mapping = ["alpha": 1, "beta": 2, "gamma": 3, "delta": 4, "eps": 5]"#,
      // No break opportunity after the leading indent: must hard force-break.
      "        veryLongIdentifierThatNeverOffersABreakOpportunityWhatsoever1234",
    ]
    for text in samples {
      let length = text.count
      // `length - 2` lands in the old `+ minimumContinuationContent` slack
      // window, which used to emit the whole over-budget line unwrapped.
      for limit in [16, 24, 40, length - 5, length - 2].filter({ $0 >= 12 }) {
        let layout = DashboardReviewFileDiffWrapLayout.layout(
          row: sourceRow(text: text),
          language: .go,
          softWrapEnabled: true,
          characterLimit: limit
        )
        for line in layout.displayLines {
          #expect(
            line.count <= limit,
            "line \"\(line)\" is \(line.count) columns, budget \(limit)"
          )
        }
      }
    }
  }

  @Test("wide CJK characters count as two columns when wrapping")
  func wideCharactersWrapByDisplayColumns() {
    // Twenty wide ideographs are 40 display columns; a 20-column budget must
    // split them so no visual line exceeds ~10 glyphs.
    let row = sourceRow(text: String(repeating: "字", count: 20))

    let layout = DashboardReviewFileDiffWrapLayout.layout(
      row: row,
      language: .generic,
      softWrapEnabled: true,
      characterLimit: 20
    )

    func columns(_ line: String) -> Int {
      line.reduce(0) { $0 + DashboardReviewFileDiffDisplayColumns.width(of: $1) }
    }
    #expect(layout.lineCount > 1)
    #expect(layout.displayLines.allSatisfy { columns($0) <= 20 })
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
