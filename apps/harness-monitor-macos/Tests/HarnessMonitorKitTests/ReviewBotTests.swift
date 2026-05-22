import Testing

@testable import HarnessMonitorKit

@Suite("Review bot detection")
struct ReviewBotTests {
  @Test("Renovate variants resolve to .renovate")
  func renovateVariantsResolveToRenovate() {
    #expect(ReviewBot.detect(authorLogin: "renovate[bot]") == .renovate)
    #expect(ReviewBot.detect(authorLogin: "Renovate[bot]") == .renovate)
    #expect(ReviewBot.detect(authorLogin: "renovate-bot") == .renovate)
  }

  @Test("Dependabot resolves to .dependabot")
  func dependabotResolvesToDependabot() {
    #expect(ReviewBot.detect(authorLogin: "dependabot[bot]") == .dependabot)
    #expect(ReviewBot.detect(authorLogin: "DEPENDABOT[bot]") == .dependabot)
  }

  @Test("Unknown authors do not resolve to a bot")
  func unknownAuthorsDoNotResolve() {
    #expect(ReviewBot.detect(authorLogin: "github-actions[bot]") == nil)
    #expect(ReviewBot.detect(authorLogin: "bart-smykla") == nil)
    #expect(ReviewBot.detect(authorLogin: "") == nil)
  }

  @Test("Rebase comment bodies match each bot's expected command")
  func rebaseCommentBodiesMatchCommands() {
    #expect(ReviewBot.renovate.rebaseCommentBody == "@renovatebot rebase")
    #expect(ReviewBot.dependabot.rebaseCommentBody == "@dependabot recreate")
  }
}
