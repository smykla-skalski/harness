import Foundation
import HarnessMonitorCore

struct MobileRemoteDaemonCommandRequest {
  let method: String
  let path: String
  let body: Data?
  let successMessage: String
}

enum MobileRemoteDaemonCommandRequestBuilder {
  static func make(
    command: MobileCommandRecord,
    agentKind: String?,
    clientID: String,
    reviewTarget: MobileRemoteDaemonResolvedReviewTarget?
  ) throws -> MobileRemoteDaemonCommandRequest {
    switch command.kind {
    case .acpPermissionDecision:
      try permissionRequest(command)
    case .taskBoardDispatch:
      try taskBoardDispatchRequest(command)
    case .taskBoardPlanApproval:
      try taskBoardPlanApprovalRequest(command, clientID: clientID)
    case .agentStart, .agentStop, .agentPrompt:
      try agentRequest(command, agentKind: agentKind)
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      try reviewRequest(command, target: try requiredReviewTarget(reviewTarget))
    case .refresh:
      try refreshRequest(command, reviewTarget: reviewTarget)
    }
  }

  static func request(
    method: String = "POST",
    path: String,
    body: [String: Any]? = nil,
    successMessage: String
  ) throws -> MobileRemoteDaemonCommandRequest {
    MobileRemoteDaemonCommandRequest(
      method: method,
      path: path,
      body: try body.map(jsonBody),
      successMessage: successMessage
    )
  }

  static func jsonBody(_ value: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else {
      throw MobileRemoteDaemonSyncError.invalidCommand("request body is not valid JSON")
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  private static func permissionRequest(
    _ command: MobileCommandRecord
  ) throws -> MobileRemoteDaemonCommandRequest {
    let agentID = try command.remoteRequiredAgentID().remotePathComponent()
    let batchID = try command.remoteRequiredPayload("batchID").remotePathComponent()
    let decision = try command.remoteRequiredPayload("decision")
    var body: [String: Any] = ["decision": decision]
    switch decision {
    case "approve_all", "deny_all":
      break
    case "approve_some":
      let requestIDs = command.remoteCSVPayload("requestIDs")
      guard !requestIDs.isEmpty else {
        throw MobileRemoteDaemonSyncError.invalidCommand("requestIDs is required")
      }
      body["request_ids"] = requestIDs
    default:
      throw MobileRemoteDaemonSyncError.invalidCommand("invalid ACP permission decision")
    }
    return try request(
      path: "/v1/managed-agents/\(agentID)/permission-batches/\(batchID)",
      body: body,
      successMessage: "Resolved the ACP permission directly."
    )
  }

  private static func taskBoardDispatchRequest(
    _ command: MobileCommandRecord
  ) throws -> MobileRemoteDaemonCommandRequest {
    let itemID = command.target.taskID?.remoteTrimmed ?? command.remoteOptionalPayload("itemID")
    guard let itemID else {
      throw MobileRemoteDaemonSyncError.invalidCommand("taskID is required")
    }
    var body: [String: Any] = [
      "item_id": itemID,
      "dry_run": try command.remoteBoolPayload("dryRun") ?? false,
    ]
    body.add("status", command.remoteOptionalPayload("status"))
    body.add("project_dir", command.remoteOptionalPayload("projectDir"))
    return try request(
      path: "/v1/task-board/dispatch",
      body: body,
      successMessage: "Dispatched the task board item directly."
    )
  }

  private static func taskBoardPlanApprovalRequest(
    _ command: MobileCommandRecord,
    clientID: String
  ) throws -> MobileRemoteDaemonCommandRequest {
    let taskID = try command.remoteRequiredTaskID().remotePathComponent()
    var body: [String: Any] = ["approved_by": clientID]
    body.add("approved_at", command.remoteOptionalPayload("approvedAt"))
    return try request(
      path: "/v1/task-board/items/\(taskID)/planning/approve",
      body: body,
      successMessage: "Approved the task board plan directly."
    )
  }

  private static func refreshRequest(
    _ command: MobileCommandRecord,
    reviewTarget: MobileRemoteDaemonResolvedReviewTarget?
  ) throws -> MobileRemoteDaemonCommandRequest {
    switch command.remoteOptionalPayload("scope") ?? "health" {
    case "health":
      return try request(method: "GET", path: "/v1/health", successMessage: "Refreshed health.")
    case "mobileMirror":
      return try request(method: "GET", path: "/v1/sessions", successMessage: "Refreshed sessions.")
    case "reviews":
      return try request(
        path: "/v1/reviews/refresh",
        body: ["targets": [try requiredReviewTarget(reviewTarget).actionTarget]],
        successMessage: "Refreshed the pull request."
      )
    case "taskBoard":
      return try request(
        path: "/v1/task-board/sync",
        body: ["direction": "both", "dry_run": true],
        successMessage: "Refreshed the task board."
      )
    case "sessionTasks":
      let sessionID = try command.remoteRequiredSessionID().remotePathComponent()
      return try request(
        method: "GET",
        path: "/v1/sessions/\(sessionID)",
        successMessage: "Refreshed the session tasks."
      )
    case let scope:
      throw MobileRemoteDaemonSyncError.invalidCommand("unknown refresh scope: \(scope)")
    }
  }

  private static func requiredReviewTarget(
    _ target: MobileRemoteDaemonResolvedReviewTarget?
  ) throws -> MobileRemoteDaemonResolvedReviewTarget {
    guard let target else {
      throw MobileRemoteDaemonSyncError.invalidCommand("review target was not resolved")
    }
    return target
  }
}
