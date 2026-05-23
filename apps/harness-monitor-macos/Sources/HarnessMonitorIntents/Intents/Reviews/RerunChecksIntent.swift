import AppIntents
import Foundation
import HarnessMonitorKit

public struct RerunChecksIntent: AppIntent {
  public static var title: LocalizedStringResource { "Rerun Pull Request Checks" }
  public static var description: IntentDescription {
    IntentDescription(
      "Restart every check suite attached to a pull request.",
      categoryName: "Reviews",
      searchKeywords: ["rerun", "retry", "checks", "ci", "pr"]
    )
  }

  @Parameter(title: "Pull Request")
  public var pullRequest: PullRequestEntity

  let source: ReviewsActionSource

  public init() {
    self.source = DaemonReviewsActionSource()
  }

  init(pullRequest: PullRequestEntity, source: ReviewsActionSource) {
    self.source = source
    self.pullRequest = pullRequest
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await applyRerun()
    return .result(dialog: IntentDialog("Reran checks for \(pullRequest.title)."))
  }

  func applyRerun() async throws {
    try await source.rerunChecks(pullRequestID: pullRequest.id)
  }
}
