import AppIntents
import Foundation
import HarnessMonitorKit

public struct MergePullRequestIntent: AppIntent {
  public static var title: LocalizedStringResource { "Merge Pull Request" }
  public static var description: IntentDescription {
    IntentDescription(
      """
      Merge a pull request using the chosen merge method (squash, merge \
      commit, or rebase).
      """,
      categoryName: "Reviews",
      searchKeywords: ["merge", "land", "ship", "pr", "squash", "rebase"]
    )
  }

  @Parameter(title: "Pull Request")
  public var pullRequest: PullRequestEntity
  @Parameter(title: "Method", default: .squash)
  public var method: MergeMethodEnum

  let source: ReviewsActionSource

  public init() {
    self.source = DaemonReviewsActionSource()
  }

  init(
    pullRequest: PullRequestEntity,
    method: MergeMethodEnum,
    source: ReviewsActionSource
  ) {
    self.source = source
    self.pullRequest = pullRequest
    self.method = method
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requestConfirmation(
      dialog: IntentDialog(
        "\(method.confirmationVerbPhrase) \(pullRequest.title)?"
      )
    )
    try await applyMerge()
    await IntentWidgetReloader.shared.reloadNeedsMeCount()
    return .result(
      dialog: IntentDialog("Merged \(pullRequest.title) via \(method.pastDescriptor)")
    )
  }

  func applyMerge() async throws {
    try await source.merge(
      pullRequestID: pullRequest.id,
      method: method.daemonValue
    )
  }
}
