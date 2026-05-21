import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown image rendering")
struct HarnessMarkdownImageRenderingTests {
  @Test("Inline parser keeps badge images inside links")
  func inlineParserKeepsBadgeImagesInsideLinks() {
    let inlines = HarnessMarkdownInlineParser.parse(
      "[![OpenSSF Scorecard](https://img.shields.io/score.svg)](https://scorecard.example)"
    )

    #expect(
      inlines == [
        .link(
          label: [
            .image(
              HarnessMarkdownImage(
                source: "https://img.shields.io/score.svg",
                alt: "OpenSSF Scorecard",
                title: nil
              ))
          ],
          destination: "https://scorecard.example",
          title: nil,
        )
      ])
  }

  @Test("Parser supports reference and HTML images")
  func parserSupportsReferenceAndHTMLImages() {
    let document = HarnessMarkdownParser.parse(
      """
      ![Score][score]

      <img src="https://example.com/badge.svg" alt="Badge" title="Score">

      [score]: https://example.com/score.svg "Scorecard"
      """
    )

    guard case .paragraph(let paragraph)? = document.blocks.first else {
      Issue.record("Expected image paragraph")
      return
    }
    #expect(
      paragraph == [
        .image(
          HarnessMarkdownImage(
            source: "https://example.com/score.svg",
            alt: "Score",
            title: "Scorecard"
          ))
      ])

    guard case .html(let html)? = document.blocks.dropFirst().first else {
      Issue.record("Expected HTML image block")
      return
    }
    #expect(
      html == [
        .image(
          HarnessMarkdownImage(
            source: "https://example.com/badge.svg",
            alt: "Badge",
            title: "Score"
          ))
      ])
  }

  @Test("Comment-only task checkboxes still render a list row")
  func commentOnlyTaskCheckboxesStillRenderAListRow() {
    let document = HarnessMarkdownParser.parse(
      """
      - [ ] <!-- rebase-check -->
      - [ ] Rebase when ready
      """
    )

    guard case .unorderedList(let items)? = document.blocks.first else {
      Issue.record("Expected task list")
      return
    }
    #expect(items.count == 2)
    #expect(items[0].checkbox == false)
    #expect(!items[0].rendersVisibleContent)
    #expect(items[0].rendersListRow)
    #expect(items[1].rendersVisibleContent)
    #expect(items[1].rendersListRow)
  }
}
