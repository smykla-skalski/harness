import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review inline title")
@MainActor
struct DashboardReviewInlineTitleTests {
  @Test("inline title maps backticked runs to code spans and strips them for accessibility")
  func inlineTitleMapsBacktickedRuns() {
    let title = DashboardReviewInlineTitle(
      title: "Bump `mise` task for `monitor:test`",
      hidesSemanticPrefix: false,
      font: .body,
      codeFont: .body.monospaced()
    )

    #expect(
      title.inlines
        == [
          .text("Bump "),
          .code("mise"),
          .text(" task for "),
          .code("monitor:test"),
        ]
    )
    #expect(title.accessibilityText == "Bump mise task for monitor:test")
  }

  @Test("inline title falls back to the plain display title without backticks")
  func inlineTitlePlainFallback() {
    let title = DashboardReviewInlineTitle(
      title: "Bump dependency",
      hidesSemanticPrefix: false,
      font: .body,
      codeFont: .body.monospaced()
    )

    #expect(title.inlines == nil)
    #expect(title.accessibilityText == "Bump dependency")
  }

  @Test("inline title strips the semantic prefix when requested")
  func inlineTitleStripsSemanticPrefix() {
    let title = DashboardReviewInlineTitle(
      title: "feat(monitor): add `flag` support",
      hidesSemanticPrefix: true,
      font: .body,
      codeFont: .body.monospaced()
    )

    #expect(title.accessibilityText == "add flag support")
    #expect(title.inlines == [.text("add "), .code("flag"), .text(" support")])
  }

  @Test("markdown default inline code colours come from the shared theme constants")
  func markdownDefaultMatchesThemeConstants() {
    #expect(
      HarnessMarkdownColorSettings.default.inlineCodeText == HarnessMonitorTheme.inlineCodeText)
    #expect(
      HarnessMarkdownColorSettings.default.inlineCodeBackground
        == HarnessMonitorTheme.inlineCodeBackground
    )
  }

  @Test("task-board inline code colours come from the shared theme constants")
  func taskBoardInlineCodeMatchesThemeConstants() {
    let view = TaskBoardInlineCodeText("x", font: .body, codeFont: .body.monospaced())

    #expect(view.codeForeground == HarnessMonitorTheme.inlineCodeText)
    #expect(view.codeBackground == HarnessMonitorTheme.inlineCodeBackground)
  }

  @Test("markdown and task-board renderers paint code spans with identical colours")
  func renderersAgreeOnCodeSpanColours() {
    let markdown = HarnessMarkdownInlineRenderer.attributedString(
      from: [.text("run "), .code("monitor:test")],
      style: HarnessMarkdownInlineRenderStyle(
        font: .body,
        codeFont: .body.monospaced(),
        colors: .default
      )
    )
    let taskBoard = TaskBoardInlineCodeFormatter.attributedText(
      for: "run `monitor:test`",
      codeFont: .body.monospaced()
    )

    #expect(codeBackgrounds(markdown) == codeBackgrounds(taskBoard))
    #expect(codeForegrounds(markdown) == codeForegrounds(taskBoard))
    #expect(codeBackgrounds(markdown) == [HarnessMonitorTheme.inlineCodeBackground])
    #expect(codeForegrounds(markdown) == [HarnessMonitorTheme.inlineCodeText])
  }

  /// Backgrounds of the runs that carry one (i.e. the inline-code spans).
  private func codeBackgrounds(_ string: AttributedString) -> [Color] {
    string.runs.compactMap(\.backgroundColor)
  }

  /// Foregrounds of the inline-code spans (runs that carry a background).
  private func codeForegrounds(_ string: AttributedString) -> [Color] {
    string.runs.compactMap { run in
      run.backgroundColor == nil ? nil : run.foregroundColor
    }
  }
}
