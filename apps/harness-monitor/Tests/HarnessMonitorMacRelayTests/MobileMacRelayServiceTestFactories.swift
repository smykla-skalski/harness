import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

func mobileMirrorHealth() -> HealthResponse {
  HealthResponse(
    status: "ok",
    version: "1.0.0",
    pid: 1,
    endpoint: "http://127.0.0.1:1",
    startedAt: "2023-11-14T22:00:00Z",
    projectCount: 1,
    sessionCount: 1
  )
}

func mobileMirrorSession() -> SessionSummary {
  SessionSummary(
    projectId: "project",
    projectName: "Harness",
    sessionId: "session-1",
    branchRef: "main",
    title: "Mobile relay",
    context: "Shipping the mobile relay.",
    status: .active,
    createdAt: "2023-11-14T22:00:00Z",
    updatedAt: "2023-11-14T22:01:00Z",
    lastActivityAt: "2023-11-14T22:02:00Z",
    leaderId: nil,
    observeId: nil,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(activeAgentCount: 1)
  )
}

func mobileMirrorAcpAgent(
  sessionID: String,
  batchID: String
) -> ManagedAgentSnapshot {
  .acp(
    AcpAgentSnapshot(
      acpId: "acp-1",
      sessionId: sessionID,
      agentId: "agent-1",
      displayName: "Codex",
      status: .active,
      pid: 123,
      pgid: 123,
      projectDir: "/repo",
      pendingPermissions: 1,
      permissionQueueDepth: 1,
      pendingPermissionBatches: [
        AcpPermissionBatch(
          batchId: batchID,
          acpId: "acp-1",
          sessionId: sessionID,
          requests: [],
          createdAt: "2023-11-14T22:03:00Z"
        )
      ],
      terminalCount: 0,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:03:00Z"
    )
  )
}

func taskBoardItem(
  id: String,
  status: TaskBoardStatus,
  priority: TaskBoardPriority
) -> TaskBoardItem {
  TaskBoardItem(
    schemaVersion: 1,
    id: id,
    title: "Review \(id)",
    body: "Review \(id) before the agent continues.",
    status: status,
    priority: priority,
    tags: ["mobile"],
    projectId: "project",
    agentMode: .planning,
    externalRefs: [],
    planning: TaskBoardPlanningState(summary: "Ready for review."),
    workflow: nil,
    sessionId: "session-1",
    workItemId: nil,
    usage: TaskBoardUsage(),
    createdAt: "2023-11-14T22:00:00Z",
    updatedAt: id == "task-blocked" ? "2023-11-14T22:04:00Z" : "2023-11-14T22:03:00Z",
    deletedAt: nil
  )
}

func reviewItem(
  pullRequestID: String = "review-1",
  number: UInt64 = 812,
  updatedAt: String = "2023-11-14T22:04:00Z"
) -> ReviewItem {
  ReviewItem(
    pullRequestID: pullRequestID,
    repositoryID: "repo-1",
    repository: "smykla-skalski/harness",
    number: number,
    title: "Add mobile relay",
    url: "https://github.com/smykla-skalski/harness/pull/\(number)",
    authorLogin: "codex",
    state: .open,
    mergeable: .mergeable,
    reviewStatus: .reviewRequired,
    checkStatus: .success,
    policyBlocked: false,
    isDraft: false,
    headSha: "abc123",
    additions: 10,
    deletions: 1,
    createdAt: "2023-11-14T22:00:00Z",
    updatedAt: updatedAt
  )
}

func trustedDevice(
  for identity: MobileDeviceIdentity
) throws -> MobileTrustedCommandDevice {
  MobileTrustedCommandDevice(
    id: identity.id,
    signingKeyFingerprint: try identity.signingKeyFingerprint(),
    signingPublicKeyRawRepresentation: try identity.signingPublicKeyRawRepresentation()
  )
}

func command(
  kind: MobileCommandKind,
  target: MobileCommandTarget,
  payload: [String: String] = [:]
) -> MobileCommandRecord {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  return MobileCommandRecord(
    id: "command-\(kind.rawValue)-\(UUID().uuidString)",
    stationID: target.stationID,
    kind: kind,
    risk: kind == .pullRequestMerge ? .destructive : .high,
    status: .queued,
    title: kind.title,
    confirmationText: kind.title,
    auditReason: kind == .pullRequestMerge ? "Confirmed from test." : nil,
    target: target,
    payload: payload,
    actorDeviceID: "device-phone",
    createdAt: now,
    expiresAt: now.addingTimeInterval(60),
    updatedAt: now
  )
}

func workItem(
  id: String,
  title: String,
  context: String?,
  severity: TaskSeverity,
  status: TaskStatus,
  blockedReason: String? = nil,
  updatedAt: String = "2023-11-14T22:00:00Z"
) -> WorkItem {
  WorkItem(
    taskId: id,
    title: title,
    context: context,
    severity: severity,
    status: status,
    assignedTo: nil,
    createdAt: "2023-11-14T22:00:00Z",
    updatedAt: updatedAt,
    createdBy: "tester",
    notes: [],
    suggestedFix: nil,
    source: .manual,
    blockedReason: blockedReason,
    completedAt: nil,
    checkpointSummary: nil
  )
}

func makeGitHubCheckout(remoteURL: String) throws -> URL {
  let checkoutRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let gitDirectory = checkoutRoot.appendingPathComponent(".git", isDirectory: true)
  try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
  let config = """
    [remote "origin"]
      url = \(remoteURL)
    """
  try Data(config.utf8).write(to: gitDirectory.appendingPathComponent("config"))
  return checkoutRoot
}

actor ReviewQueryRecorder {
  private var recordedRequests: [ReviewsQueryRequest] = []

  func record(_ request: ReviewsQueryRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [ReviewsQueryRequest] {
    recordedRequests
  }
}

actor ReviewDetailRecorder {
  private var fileRequests: [String] = []
  private var timelineRequests: [String] = []

  func recordFileRequest(_ pullRequestID: String) {
    fileRequests.append(pullRequestID)
  }

  func recordTimelineRequest(_ pullRequestID: String) {
    timelineRequests.append(pullRequestID)
  }

  func fileRequestIDs() -> [String] {
    fileRequests
  }

  func timelineRequestIDs() -> [String] {
    timelineRequests
  }
}

actor RecordingMobileRelayCommandClient: MobileRelayCommandClient {
  private var recordedEvents: [String] = []

  func events() -> [String] {
    recordedEvents
  }

  func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> String {
    recordedEvents.append("acp:\(agentID):\(batchID):\(decision.eventValue)")
    return "ACP resolved."
  }

  func dispatchTaskBoard(_ request: TaskBoardDispatchRequest) async throws -> String {
    recordedEvents.append(
      "dispatch:\(request.itemId ?? ""):\(request.status?.rawValue ?? "")"
        + ":\(request.dryRun):\(request.projectDir ?? "")"
    )
    return "Task dispatched."
  }

  func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> String {
    recordedEvents.append("approve-plan:\(id):\(request.approvedBy)")
    return "Plan approved."
  }

  func startAgent(
    sessionID: String,
    request: MobileRelayAgentStartRequest
  ) async throws -> String {
    recordedEvents.append(
      "start-agent:\(sessionID):\(request.family.rawValue):\(request.agent):\(request.prompt ?? "")"
    )
    return "Agent started."
  }

  func stopAgent(agentID: String) async throws -> String {
    recordedEvents.append("stop-agent:\(agentID)")
    return "Agent stopped."
  }

  func promptAgent(agentID: String, prompt: String) async throws -> String {
    recordedEvents.append("prompt-agent:\(agentID):\(prompt)")
    return "Agent prompted."
  }

  func approvePullRequest(_ target: ReviewTarget) async throws -> String {
    recordedEvents.append("approve-pr:\(target.repository)#\(target.number)")
    return "PR approved."
  }

  func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String {
    recordedEvents.append("label-pr:\(target.repository)#\(target.number):\(label)")
    return "PR labeled."
  }

  func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String {
    recordedEvents.append("rerun-pr:\(target.repository)#\(target.number)")
    return "Checks rerun."
  }

  func mergePullRequest(
    _ target: ReviewTarget,
    method: TaskBoardGitHubMergeMethod
  ) async throws -> String {
    recordedEvents.append(
      "merge-pr:\(target.repository)#\(target.number):\(method.rawValue):\(target.headSha)"
    )
    return "PR merged."
  }

  func refreshMobileMirror() async throws -> String {
    recordedEvents.append("refresh-mobile-mirror")
    return "Refreshed."
  }

  func refreshReviews(_ target: ReviewTarget?) async throws -> String {
    let targetLabel = target.map { "\($0.repository)#\($0.number)" } ?? "none"
    recordedEvents.append("refresh-reviews:\(targetLabel)")
    return "Refreshed."
  }

  func refreshTaskBoard() async throws -> String {
    recordedEvents.append("refresh-task-board")
    return "Refreshed."
  }

  func refreshSessionTasks(sessionID: String, taskID: String?) async throws -> String {
    recordedEvents.append("refresh-session-tasks:\(sessionID):\(taskID ?? "")")
    return "Refreshed."
  }
}

extension AcpPermissionDecision {
  var eventValue: String {
    switch self {
    case .approveAll:
      "approveAll"
    case .approveSome(let requestIDs):
      "approveSome:\(requestIDs.joined(separator: ","))"
    case .denyAll:
      "denyAll"
    }
  }
}
