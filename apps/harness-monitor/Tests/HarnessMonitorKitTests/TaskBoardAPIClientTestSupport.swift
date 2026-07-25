import Foundation
import Testing

@testable import HarnessMonitorKit

actor RPCProbe {
  struct Call: Sendable {
    let method: WebSocketRPCMethod
    let params: JSONValue?
  }

  private(set) var calls: [Call] = []

  func record(method: WebSocketRPCMethod, params: JSONValue?) {
    calls.append(Call(method: method, params: params))
  }
}

func taskBoardRPCResponse(for method: WebSocketRPCMethod) throws -> JSONValue {
  guard let response = taskBoardRPCResponses[method] else {
    Issue.record("Unexpected RPC method \(method.rawValue)")
    throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
  }
  return response
}

private func fixtureJSONValue(_ text: String) -> JSONValue {
  let data = Data(text.utf8)
  do {
    return try JSONDecoder().decode(JSONValue.self, from: data)
  } catch {
    fatalError("Unable to decode JSONValue fixture: \(error)")
  }
}

let sampleTaskBoardAutomationHistoryText = #"""
  {
    "runs": [{
      "run_id": "run/42 ?#%", "trigger": "manual", "state": "terminal",
      "outcome": "completed", "dry_run": false, "scope": {"item_id": "board-1"},
      "started_at": "2026-07-19T12:00:00Z", "heartbeat_at": "2026-07-19T12:01:00Z",
      "completed_at": "2026-07-19T12:02:00Z"
    }],
    "next_cursor": "cursor-2", "has_older": true
  }
  """#

let sampleTaskBoardAutomationDetailText = #"""
  {
    "run": {
      "run_id": "run/42 ?#%", "trigger": "manual", "state": "terminal",
      "outcome": "completed", "dry_run": false, "scope": {"item_id": "board-1"},
      "started_at": "2026-07-19T12:00:00Z", "heartbeat_at": "2026-07-19T12:01:00Z",
      "completed_at": "2026-07-19T12:02:00Z"
    },
    "stages": [{
      "sequence": 1, "stage": "reconcile", "state": "completed",
      "recorded_at": "2026-07-19T12:01:30Z", "summary": "Reconciled one item"
    }]
  }
  """#

let sampleTaskBoardAutomationMetricsText = #"""
  {
    "runs_total": 9, "runs_running": 1, "runs_completed": 5, "runs_noop": 1,
    "runs_partial": 1, "runs_failed": 1, "runs_cancelled": 1, "open_conflicts": 2,
    "captured_at": "2026-07-19T12:03:00Z"
  }
  """#

let sampleTaskBoardAutomationForceCancelText = #"""
  {"disposition":"accepted_pending"}
  """#

private let taskBoardRPCResponses: [WebSocketRPCMethod: JSONValue] = [
  .taskBoardCapabilities: .object([
    "storage": .string("database"),
    "revision": .number(7),
    "instance_id": .string("task-board-instance-1"),
  ]),
  .taskBoardList: .object([
    "items": .array([.object(sampleTaskBoardItemJSON)]),
    "items_change_seq": .number(42),
    "item_revisions": .object(["board-1": .number(7)]),
  ]),
  .taskBoardPositionGet: .object(sampleTaskBoardPositionSnapshotJSON),
  .taskBoardPositionSet: .object(sampleTaskBoardPositionMutationJSON),
  .taskBoardPositionReset: .object(sampleTaskBoardPositionMutationJSON),
  .taskBoardTriageGet: fixtureJSONValue(sampleTaskBoardTriageCurrentText),
  .taskBoardTriageHistory: fixtureJSONValue(sampleTaskBoardTriageHistoryText),
  .taskBoardCreate: .object(sampleTaskBoardItemJSON),
  .taskBoardGet: .object(sampleTaskBoardItemJSON),
  .taskBoardUpdate: .object(sampleTaskBoardItemJSON),
  .taskBoardDelete: .object(sampleTaskBoardItemJSON),
  .taskBoardPlanBegin: .object(sampleTaskBoardPlanningResponseJSON),
  .taskBoardPlanSubmit: .object(sampleTaskBoardPlanningResponseJSON),
  .taskBoardPlanApprove: .object(sampleTaskBoardPlanningResponseJSON),
  .taskBoardSync: .object(sampleTaskBoardSyncSummaryJSON),
  .taskBoardDispatch: .object(sampleTaskBoardDispatchSummaryJSON),
  .taskBoardEvaluate: .object(sampleTaskBoardEvaluationSummaryJSON),
  .taskBoardAudit: .object([
    "total": .number(1),
    "ready": .number(1),
    "blocked": .number(0),
    "deleted": .number(0),
    "by_status": .array([]),
  ]),
  .taskBoardProjects: .array([
    .object([
      "project_id": .string("project-0123456789abcdef0123456789abcdef"),
      "source": .string("github"),
      "slug": .string("acme/widgets"),
      "color": .string("teal"),
      "shape": .string("circle"),
      "item_count": .number(1),
      "ready_count": .number(1),
    ])
  ]),
  .taskBoardMachines: .array([
    .object([
      "mode": .string("interactive"),
      "item_count": .number(1),
      "ready_count": .number(1),
    ])
  ]),
  .taskBoardOrchestratorStatus: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorStart: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorStop: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorRunOnce: .object(sampleTaskBoardOrchestratorRunOnceJSON),
  .taskBoardOrchestratorSettingsGet: .object(sampleTaskBoardOrchestratorSettingsJSON),
  .taskBoardOrchestratorSettingsUpdate: .object(sampleTaskBoardOrchestratorSettingsJSON),
  .taskBoardOrchestratorRuns: fixtureJSONValue(sampleTaskBoardAutomationHistoryText),
  .taskBoardOrchestratorRunDetail: fixtureJSONValue(sampleTaskBoardAutomationDetailText),
  .taskBoardOrchestratorMetrics: fixtureJSONValue(sampleTaskBoardAutomationMetricsText),
  .taskBoardOrchestratorForceCancel:
    fixtureJSONValue(sampleTaskBoardAutomationForceCancelText),
  .taskBoardOrchestratorRuntimeConfigGet: .object(sampleTaskBoardGitRuntimeConfigJSON),
  .taskBoardOrchestratorRuntimeConfigUpdate: .object(sampleTaskBoardGitRuntimeConfigJSON),
  .taskBoardOrchestratorGitHubTokensSync: .object(sampleGitHubTokensSyncJSON),
  .taskBoardGitRuntimeSecretHandoffPrepare: .object([
    "prepared": .bool(true),
    "migration_id": .string("migration-1"),
    "digest": .string("digest-1"),
    "runtime": .object(sampleTaskBoardGitRuntimeConfigJSON),
  ]),
  .taskBoardGitRuntimeSecretHandoffAck: .object(["acknowledged": .bool(true)]),
  .taskBoardGitRuntimeKeyMaterialSync: .object(["synchronized": .bool(true)]),
  .policyCanvasWorkspaceGet: .object(samplePolicyCanvasWorkspaceJSON),
  .policyCanvasCreate: .object(samplePolicyCanvasWorkspaceCreatedJSON),
  .policyCanvasDuplicate: .object(samplePolicyCanvasWorkspaceDuplicateJSON),
  .policyCanvasRename: .object(samplePolicyCanvasWorkspaceRenamedJSON),
  .policyCanvasSetActive: .object(samplePolicyCanvasWorkspaceActivatedJSON),
  .policyCanvasDelete: .object(samplePolicyCanvasWorkspaceDeletedJSON),
  .policyScenarioCreate: .object(samplePolicyCanvasWorkspaceJSON),
  .policyScenarioUpdate: .object(samplePolicyCanvasWorkspaceJSON),
  .policyScenarioDelete: .object(samplePolicyCanvasWorkspaceJSON),
  .policyScenarioReset: .object(samplePolicyCanvasWorkspaceJSON),
  .policyPipelineGet: .object(samplePolicyPipelineJSON),
  .policyPipelineSaveDraft: .object(samplePolicySaveDraftJSON),
  .policyPipelineSimulate: .object(samplePolicySimulationJSON),
  .policyPipelinePromote: .object(samplePolicyPromotionJSON),
  .policyPipelineMakeLive: .object(samplePolicyMakeLiveJSON),
  .policyPipelineGoLiveDiff: .object(samplePolicyGoLiveDiffJSON),
  .policyPipelineReplay: fixtureJSONValue(samplePolicyReplayText),
  .policyPipelineAudit: .object(samplePolicyAuditJSON),
  .policyCanvasExport: .object(samplePolicyCanvasExportJSON),
  .policyCanvasImport: .object(samplePolicyCanvasWorkspaceJSON),
  .reviewsRepositoryCatalog:
    fixtureJSONValue(sampleDepsCatalogResponseText),
  .reviewsCapabilities: fixtureJSONValue(sampleReviewsCapabilitiesResponseText),
  .reviewsQuery: fixtureJSONValue(sampleReviewsQueryResponseText),
  .reviewsActionPreview: fixtureJSONValue(sampleActionPreviewText),
  .reviewsApprove: fixtureJSONValue(sampleDepsApproveResponseText),
  .reviewsMerge: fixtureJSONValue(sampleReviewsMergeResponseText),
  .reviewsRerunChecks: fixtureJSONValue(sampleReviewsRerunResponseText),
  .reviewsAddLabel: fixtureJSONValue(sampleReviewsLabelResponseText),
  .reviewsAuto: fixtureJSONValue(sampleReviewsAutoResponseText),
  .reviewsPolicyPreview: fixtureJSONValue(sampleReviewsPolicyPreviewResponseText),
  .reviewsPolicyStart: fixtureJSONValue(sampleReviewsPolicyRunResponseText),
  .reviewsPolicyStatus: fixtureJSONValue(sampleReviewsPolicyStatusResponseText),
  .reviewsPolicyHistory: fixtureJSONValue(sampleReviewsPolicyHistoryResponseText),
  .reviewsClearCache: fixtureJSONValue(sampleDepsCacheClearResponseText),
  .reviewsBody: fixtureJSONValue(sampleReviewsBodyResponseText),
  .reviewsRefresh: fixtureJSONValue(sampleReviewsRefreshResponseText),
  .reviewsPullRequestsResolve:
    fixtureJSONValue(sampleReviewsPRResolveText),
  .reviewsComment: fixtureJSONValue(sampleReviewsCommentResponseText),
  .reviewsAvatar: fixtureJSONValue(sampleReviewsAvatarResponseText),
  .reviewsBodyUpdate: fixtureJSONValue(sampleReviewsBodyUpdateResponseText),
  .reviewsFilesComment: fixtureJSONValue(sampleReviewsFileCommentResponseText),
  .reviewsReviewThreadsResolve:
    fixtureJSONValue(sampleReviewsThreadResolveText),
  .reviewsFilesList: fixtureJSONValue(sampleReviewsFilesListResponseText),
  .reviewsFilesPatch: fixtureJSONValue(sampleReviewsFilesPatchResponseText),
  .reviewsFilesPreview: fixtureJSONValue(sampleReviewsFilesPreviewResponseText),
  .reviewsFilesViewed: fixtureJSONValue(sampleReviewsFilesViewedResponseText),
  .reviewsFilesBlob: fixtureJSONValue(sampleReviewsFilesBlobResponseText),
  .reviewsFilesLocalClonesList:
    fixtureJSONValue(sampleReviewsLocalClonesText),
  .reviewsTimeline: fixtureJSONValue(sampleReviewsTimelineResponseText),
]
