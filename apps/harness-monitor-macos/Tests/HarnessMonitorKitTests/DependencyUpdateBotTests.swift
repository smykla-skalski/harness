import Testing

@testable import HarnessMonitorKit

@Suite("Dependency update bot detection")
struct DependencyUpdateBotTests {
  @Test("Renovate variants resolve to .renovate")
  func renovateVariantsResolveToRenovate() {
    #expect(DependencyUpdateBot.detect(authorLogin: "renovate[bot]") == .renovate)
    #expect(DependencyUpdateBot.detect(authorLogin: "Renovate[bot]") == .renovate)
    #expect(DependencyUpdateBot.detect(authorLogin: "renovate-bot") == .renovate)
  }

  @Test("Dependabot resolves to .dependabot")
  func dependabotResolvesToDependabot() {
    #expect(DependencyUpdateBot.detect(authorLogin: "dependabot[bot]") == .dependabot)
    #expect(DependencyUpdateBot.detect(authorLogin: "DEPENDABOT[bot]") == .dependabot)
  }

  @Test("Unknown authors do not resolve to a bot")
  func unknownAuthorsDoNotResolve() {
    #expect(DependencyUpdateBot.detect(authorLogin: "github-actions[bot]") == nil)
    #expect(DependencyUpdateBot.detect(authorLogin: "bart-smykla") == nil)
    #expect(DependencyUpdateBot.detect(authorLogin: "") == nil)
  }

  @Test("Rebase comment bodies match each bot's expected command")
  func rebaseCommentBodiesMatchCommands() {
    #expect(DependencyUpdateBot.renovate.rebaseCommentBody == "@renovatebot rebase")
    #expect(DependencyUpdateBot.dependabot.rebaseCommentBody == "@dependabot recreate")
  }
}
