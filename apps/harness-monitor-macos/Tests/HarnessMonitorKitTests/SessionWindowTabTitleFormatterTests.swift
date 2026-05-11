import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window tab title formatter")
struct SessionWindowTabTitleFormatterTests {
  @Test("Returns base unchanged when there are no pending decisions")
  func basePassesThroughWhenCountIsZero() {
    let title = SessionWindowTabTitleFormatter.decoratedTitle(
      base: "e2e flow validation",
      pendingDecisionCount: 0
    )

    #expect(title == "e2e flow validation")
  }

  @Test("Appends parenthesized count for one pending decision")
  func appendsParenthesizedCountForSingleDecision() {
    let title = SessionWindowTabTitleFormatter.decoratedTitle(
      base: "e2e",
      pendingDecisionCount: 1
    )

    #expect(title == "e2e (1)")
  }

  @Test("Appends parenthesized count for many pending decisions")
  func appendsParenthesizedCountForManyDecisions() {
    let title = SessionWindowTabTitleFormatter.decoratedTitle(
      base: "session-42",
      pendingDecisionCount: 17
    )

    #expect(title == "session-42 (17)")
  }

  @Test("Treats negative counts as zero")
  func negativeCountFallsBackToBase() {
    let title = SessionWindowTabTitleFormatter.decoratedTitle(
      base: "scratch",
      pendingDecisionCount: -3
    )

    #expect(title == "scratch")
  }
}
