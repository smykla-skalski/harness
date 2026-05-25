import AppIntents
import Foundation
import HarnessMonitorKit

/// Parametric review-action intent for Shortcuts users who want to pick
/// the verb at build time (e.g. an If-block that approves on one branch
/// and merges on another). Specific intents like `ApprovePullRequestIntent`
/// remain for callers that already know the verb and want a tighter
/// shortcut surface. Confirmation matches the underlying verb's rule:
/// approve and merge confirm, rerun and add-label are idempotent and skip
public struct PerformReviewActionIntent: AppIntent {
  public static var title: LocalizedStringResource { "Perform Review Action" }
  public static var description: IntentDescription {
    IntentDescription(
      "Run a chosen review action (approve, merge, rerun checks, add label) on a pull request",
      categoryName: "Reviews",
      searchKeywords: ["review", "action", "approve", "merge", "rerun", "label"]
    )
  }

  @Parameter(title: "Action")
  public var action: ReviewActionEnum

  @Parameter(title: "Pull Request")
  public var pullRequest: PullRequestEntity

  @Parameter(
    title: "Merge Method",
    description: "Required when Action is Merge"
  )
  public var mergeMethod: MergeMethodEnum?

  @Parameter(
    title: "Label",
    description: "Required when Action is Add Label"
  )
  public var label: String?

  let source: ReviewsActionSource
  let recorder: IntentDonationRecorder

  public init() {
    self.source = DaemonReviewsActionSource()
    self.recorder = .shared
  }

  init(
    action: ReviewActionEnum,
    pullRequest: PullRequestEntity,
    mergeMethod: MergeMethodEnum? = nil,
    label: String? = nil,
    source: ReviewsActionSource,
    recorder: IntentDonationRecorder = .shared
  ) {
    self.source = source
    self.recorder = recorder
    self.action = action
    self.pullRequest = pullRequest
    self.mergeMethod = mergeMethod
    self.label = label
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    let result = try await runAction()
    await recorder.recordDonation(kind: .pullRequest, id: pullRequest.id)
    return result
  }

  private func runAction() async throws -> some IntentResult & ProvidesDialog {
    switch action {
    case .approve:
      try await requestConfirmation(
        dialog: IntentDialog("Approve \(pullRequest.title)?")
      )
      try await source.approve(pullRequestID: pullRequest.id)
      await IntentWidgetReloader.shared.reloadNeedsMeCount()
      return .result(dialog: IntentDialog("Approved \(pullRequest.title)"))

    case .merge:
      guard let mergeMethod else {
        throw IntentDaemonError.rpcFailed(
          method: "performReviewAction",
          message: "Pick a merge method to merge a pull request"
        )
      }
      try await requestConfirmation(
        dialog: IntentDialog("\(mergeMethod.confirmationVerbPhrase) \(pullRequest.title)?")
      )
      try await source.merge(pullRequestID: pullRequest.id, method: mergeMethod.daemonValue)
      await IntentWidgetReloader.shared.reloadNeedsMeCount()
      let message = "Merged \(pullRequest.title) via \(mergeMethod.pastDescriptor)"
      return .result(dialog: IntentDialog(stringLiteral: message))

    case .rerunChecks:
      try await source.rerunChecks(pullRequestID: pullRequest.id)
      return .result(dialog: IntentDialog("Reran checks for \(pullRequest.title)"))

    case .addLabel:
      let trimmed = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        throw IntentDaemonError.rpcFailed(
          method: "performReviewAction",
          message: "Provide a label to add to the pull request"
        )
      }
      try await source.addLabel(pullRequestID: pullRequest.id, label: trimmed)
      return .result(dialog: IntentDialog("Added the \(trimmed) label to \(pullRequest.title)"))
    }
  }
}
