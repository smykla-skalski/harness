import AppIntents
import Foundation
import HarnessMonitorKit

public struct AddLabelToPullRequestIntent: AppIntent {
  public static var title: LocalizedStringResource { "Add Label to Pull Request" }
  public static var description: IntentDescription {
    IntentDescription(
      "Attach a label to a pull request on GitHub.",
      categoryName: "Reviews",
      searchKeywords: ["label", "tag", "pr", "categorize"]
    )
  }

  @Parameter(title: "Pull Request")
  public var pullRequest: PullRequestEntity
  @Parameter(title: "Label")
  public var label: String

  let source: ReviewsActionSource

  public init() {
    self.source = DaemonReviewsActionSource()
  }

  init(
    pullRequest: PullRequestEntity,
    label: String,
    source: ReviewsActionSource
  ) {
    self.source = source
    self.pullRequest = pullRequest
    self.label = label
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await applyLabel()
    return .result(dialog: IntentDialog("Added \(label) to \(pullRequest.title)."))
  }

  func applyLabel() async throws {
    try await source.addLabel(pullRequestID: pullRequest.id, label: label)
  }
}
