import Foundation
import HarnessMonitorCore

extension MobileRemoteDaemonCommandRequestBuilder {
  static func reviewRequest(
    _ command: MobileCommandRecord,
    target: MobileRemoteDaemonResolvedReviewTarget
  ) throws -> MobileRemoteDaemonCommandRequest {
    let actionTarget = target.actionTarget
    switch command.kind {
    case .pullRequestApprove:
      return try request(
        path: "/v1/reviews/approve",
        body: ["targets": [actionTarget]],
        successMessage: "Approved the pull request directly."
      )
    case .pullRequestLabel:
      return try request(
        path: "/v1/reviews/labels",
        body: [
          "targets": [actionTarget],
          "label": try command.remoteRequiredPayload("label"),
        ],
        successMessage: "Labeled the pull request directly."
      )
    case .pullRequestRerunChecks:
      return try request(
        path: "/v1/reviews/rerun-checks",
        body: ["targets": [actionTarget]],
        successMessage: "Reran pull request checks directly."
      )
    case .pullRequestMerge:
      return try request(
        path: "/v1/reviews/merge",
        body: [
          "targets": [actionTarget],
          "method": try mergeMethod(command),
        ],
        successMessage: "Merged the pull request directly."
      )
    default:
      throw MobileRemoteDaemonSyncError.invalidCommand("not a review command")
    }
  }

  static func reviewReference(
    _ command: MobileCommandRecord
  ) throws -> MobileRemoteDaemonReviewReference? {
    let needsReview: Bool
    switch command.kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      needsReview = true
    case .refresh:
      needsReview = command.remoteOptionalPayload("scope") == "reviews"
    default:
      needsReview = false
    }
    guard needsReview else { return nil }

    let repository = try command.remoteRequiredPayload("repository")
    let number = try positiveReviewNumber(command)
    return MobileRemoteDaemonReviewReference(repository: repository, number: number)
  }

  private static func positiveReviewNumber(_ command: MobileCommandRecord) throws -> Int {
    guard let raw = command.remoteOptionalPayload("number"),
      let number = Int(raw),
      number > 0
    else {
      throw MobileRemoteDaemonSyncError.invalidCommand("number must be a positive integer")
    }
    return number
  }

  private static func mergeMethod(_ command: MobileCommandRecord) throws -> String {
    let method = command.remoteOptionalPayload("method") ?? "squash"
    guard ["merge", "squash", "rebase"].contains(method) else {
      throw MobileRemoteDaemonSyncError.invalidCommand("invalid merge method: \(method)")
    }
    return method
  }
}
