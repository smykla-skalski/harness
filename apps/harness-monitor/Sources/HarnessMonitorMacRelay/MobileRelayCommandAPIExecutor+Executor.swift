import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

public struct HarnessMonitorClientMobileRelayCommandExecutor: MobileRelayCommandExecutor {
  private let client: any MobileRelayCommandClient
  private let now: @Sendable () -> Date

  public init(
    client: any MobileRelayCommandClient,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.now = now
  }

  public func execute(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> MobileCommandReceipt {
    let message = try await executeCommand(command, snapshot: snapshot)
    let completedAt = now()
    return MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: message,
      receivedAt: completedAt,
      completedAt: completedAt,
      executionRevision: snapshot.revision
    )
  }

  private func executeCommand(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> String {
    switch command.kind {
    case .acpPermissionDecision:
      return try await client.resolveAcpPermission(
        agentID: try command.requiredAgentID(),
        batchID: try command.requiredPayload("batchID"),
        decision: try command.acpPermissionDecision()
      )
    case .taskBoardDispatch:
      return try await client.dispatchTaskBoard(command.taskBoardDispatchRequest())
    case .taskBoardPlanApproval:
      return try await client.approveTaskBoardPlan(
        id: try command.requiredTaskID(),
        request: command.taskBoardPlanApproveRequest()
      )
    case .agentStart:
      return try await client.startAgent(
        sessionID: try command.requiredSessionID(),
        request: try command.agentStartRequest()
      )
    case .agentStop:
      return try await client.stopAgent(agentID: try command.requiredAgentID())
    case .agentPrompt:
      return try await client.promptAgent(
        agentID: try command.requiredAgentID(),
        prompt: try command.requiredPayload("prompt")
      )
    case .pullRequestApprove:
      return try await client.approvePullRequest(command.reviewTarget(snapshot: snapshot))
    case .pullRequestLabel:
      return try await client.labelPullRequest(
        command.reviewTarget(snapshot: snapshot),
        label: try command.requiredPayload("label")
      )
    case .pullRequestRerunChecks:
      return try await client.rerunPullRequestChecks(command.reviewTarget(snapshot: snapshot))
    case .pullRequestMerge:
      return try await client.mergePullRequest(
        command.reviewTarget(snapshot: snapshot),
        method: command.mergeMethod()
      )
    case .refresh:
      return try await executeRefresh(command, snapshot: snapshot)
    }
  }

  private func executeRefresh(
    _ command: MobileCommandRecord,
    snapshot: MobileMirrorSnapshot
  ) async throws -> String {
    switch try command.refreshScope() {
    case .health, .mobileMirror:
      return try await client.refreshMobileMirror()
    case .reviews:
      let target = try command.optionalReviewTarget(snapshot: snapshot)
      return try await client.refreshReviews(target)
    case .taskBoard:
      return try await client.refreshTaskBoard()
    case .sessionTasks:
      return try await client.refreshSessionTasks(
        sessionID: try command.requiredSessionID(),
        taskID: command.target.taskID
      )
    }
  }
}
