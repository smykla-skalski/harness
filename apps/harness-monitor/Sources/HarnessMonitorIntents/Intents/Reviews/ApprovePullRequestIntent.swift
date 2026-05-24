import AppIntents
import Foundation
import HarnessMonitorKit

public struct ApprovePullRequestIntent: AppIntent {
  public static var title: LocalizedStringResource { "Approve Pull Request" }
  public static var description: IntentDescription {
    IntentDescription(
      "Approve a pull request on behalf of the signed-in viewer",
      categoryName: "Reviews",
      searchKeywords: ["approve", "review", "pr", "lgtm"]
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
    try await requestConfirmation(
      dialog: IntentDialog("Approve \(pullRequest.title)?")
    )
    try await applyApproval()
    await IntentWidgetReloader.shared.reloadNeedsMeCount()
    return .result(dialog: IntentDialog("Approved \(pullRequest.title)"))
  }

  func applyApproval() async throws {
    try await source.approve(pullRequestID: pullRequest.id)
  }
}
