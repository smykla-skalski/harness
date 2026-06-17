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

private let taskBoardRPCResponses: [WebSocketRPCMethod: JSONValue] = [
  .taskBoardList: .object(["items": .array([.object(sampleTaskBoardItemJSON)])]),
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
      "project_id": .string("project-1"),
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
  .taskBoardOrchestratorRuntimeConfigGet: .object(sampleTaskBoardGitRuntimeConfigJSON),
  .taskBoardOrchestratorRuntimeConfigUpdate: .object(sampleTaskBoardGitRuntimeConfigJSON),
  .taskBoardOrchestratorGitHubTokensSync: .object(sampleGitHubTokensSyncJSON),
  .taskBoardOrchestratorTodoistTokenSync: .object(sampleTodoistTokenSyncJSON),
  .taskBoardPolicyCanvasWorkspaceGet: .object(samplePolicyCanvasWorkspaceJSON),
  .taskBoardPolicyCanvasCreate: .object(samplePolicyCanvasWorkspaceCreatedJSON),
  .taskBoardPolicyCanvasDuplicate: .object(samplePolicyCanvasWorkspaceDuplicateJSON),
  .taskBoardPolicyCanvasRename: .object(samplePolicyCanvasWorkspaceRenamedJSON),
  .taskBoardPolicyCanvasSetActive: .object(samplePolicyCanvasWorkspaceActivatedJSON),
  .taskBoardPolicyCanvasDelete: .object(samplePolicyCanvasWorkspaceDeletedJSON),
  .taskBoardPolicyPipelineGet: .object(samplePolicyPipelineJSON),
  .taskBoardPolicyPipelineSaveDraft: .object(samplePolicySaveDraftJSON),
  .taskBoardPolicyPipelineSimulate: .object(samplePolicySimulationJSON),
  .taskBoardPolicyPipelinePromote: .object(samplePolicyPromotionJSON),
  .taskBoardPolicyPipelineAudit: .object(samplePolicyAuditJSON),
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
  .reviewsClearCache: fixtureJSONValue(sampleDepsCacheClearResponseText),
  .reviewsRefresh: fixtureJSONValue(sampleReviewsRefreshResponseText),
  .reviewsComment: fixtureJSONValue(sampleReviewsCommentResponseText),
  .reviewsAvatar: fixtureJSONValue(sampleReviewsAvatarResponseText),
  .reviewsBodyUpdate: fixtureJSONValue(sampleReviewsBodyUpdateResponseText),
  .reviewsFilesComment: fixtureJSONValue(sampleReviewsFileCommentResponseText),
  .reviewsReviewThreadsResolve:
    fixtureJSONValue(sampleReviewsReviewThreadResolveResponseText),
  .reviewsFilesList: fixtureJSONValue(sampleReviewsFilesListResponseText),
  .reviewsFilesPatch: fixtureJSONValue(sampleReviewsFilesPatchResponseText),
  .reviewsFilesPreview: fixtureJSONValue(sampleReviewsFilesPreviewResponseText),
  .reviewsFilesViewed: fixtureJSONValue(sampleReviewsFilesViewedResponseText),
  .reviewsFilesBlob: fixtureJSONValue(sampleReviewsFilesBlobResponseText),
  .reviewsTimeline: fixtureJSONValue(sampleReviewsTimelineResponseText),
]

final class TaskBoardURLProtocol: URLProtocol, @unchecked Sendable {
  struct RecordedRequest {
    let path: String
    let query: String?
    let method: String
    let body: [String: Any]?
  }

  private struct Route: Hashable {
    let path: String
    let method: String?

    init(_ path: String, method: String? = nil) {
      self.path = path
      self.method = method
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequests: [RecordedRequest] = []
  private static let responseBodies: [Route: String] = [
    Route("/v1/task-board/items", method: "GET"): #"{"items":[\#(sampleTaskBoardItemJSONString)]}"#,
    Route("/v1/task-board/items/board-1/planning/begin"): sampleTaskBoardPlanningResponseText,
    Route("/v1/task-board/items/board-1/planning/submit"): sampleTaskBoardPlanningResponseText,
    Route("/v1/task-board/items/board-1/planning/approve"): sampleTaskBoardPlanningResponseText,
    Route("/v1/task-board/sync"): sampleTaskBoardSyncSummaryText,
    Route("/v1/task-board/dispatch"): sampleTaskBoardDispatchSummaryJSONString,
    Route("/v1/task-board/evaluate"): sampleTaskBoardEvaluationSummaryText,
    Route("/v1/task-board/audit"): #"{"total":1,"ready":1,"blocked":0,"deleted":0,"by_status":[]}"#,
    Route("/v1/task-board/projects"):
      #"[{"project_id":"project-1","item_count":1,"ready_count":1}]"#,
    Route("/v1/task-board/machines"): #"[{"mode":"interactive","item_count":1,"ready_count":1}]"#,
    Route("/v1/task-board/orchestrator/status"): sampleOrchestratorStatusText,
    Route("/v1/task-board/orchestrator/start"): sampleOrchestratorStatusText,
    Route("/v1/task-board/orchestrator/stop"): sampleOrchestratorStatusText,
    Route("/v1/task-board/orchestrator/run-once"): sampleOrchestratorRunOnceText,
    Route("/v1/task-board/orchestrator/settings"): sampleOrchestratorSettingsText,
    Route("/v1/task-board/orchestrator/runtime-config"): sampleTaskBoardGitRuntimeConfigText,
    Route("/v1/task-board/orchestrator/github-tokens"): sampleGitHubTokensSyncText,
    Route("/v1/task-board/orchestrator/todoist-token"): sampleTodoistTokenSyncText,
    Route("/v1/task-board/policy/canvases", method: "GET"): samplePolicyCanvasWorkspaceText,
    Route("/v1/task-board/policy/canvases/create"): samplePolicyCanvasWorkspaceCreatedText,
    Route("/v1/task-board/policy/canvases/duplicate"): samplePolicyCanvasWorkspaceDuplicateText,
    Route("/v1/task-board/policy/canvases/rename"): samplePolicyCanvasWorkspaceRenamedText,
    Route("/v1/task-board/policy/canvases/active"): samplePolicyCanvasWorkspaceActivatedText,
    Route("/v1/task-board/policy/canvases/delete"): samplePolicyCanvasWorkspaceDeletedText,
    Route("/v1/task-board/policy/pipeline", method: "GET"): samplePolicyPipelineText,
    Route("/v1/task-board/policy/pipeline", method: "PUT"): samplePolicySaveDraftText,
    Route("/v1/task-board/policy/simulate"): samplePolicySimulationText,
    Route("/v1/task-board/policy/promote"): samplePolicyPromotionText,
    Route("/v1/task-board/policy/audit"): samplePolicyAuditText,
    Route("/v1/reviews/repositories"):
      sampleDepsCatalogResponseText,
    Route("/v1/reviews/capabilities", method: "GET"):
      sampleReviewsCapabilitiesResponseText,
    Route("/v1/reviews/query"): sampleReviewsQueryResponseText,
    Route("/v1/reviews/action-preview"):
      sampleActionPreviewText,
    Route("/v1/reviews/approve"): sampleDepsApproveResponseText,
    Route("/v1/reviews/merge"): sampleReviewsMergeResponseText,
    Route("/v1/reviews/rerun-checks"): sampleReviewsRerunResponseText,
    Route("/v1/reviews/labels"): sampleReviewsLabelResponseText,
    Route("/v1/reviews/auto"): sampleReviewsAutoResponseText,
    Route("/v1/reviews/policy/preview"): sampleReviewsPolicyPreviewResponseText,
    Route("/v1/reviews/policy/start"): sampleReviewsPolicyRunResponseText,
    Route("/v1/reviews/policy/status"): sampleReviewsPolicyStatusResponseText,
    Route("/v1/reviews/cache", method: "DELETE"):
      sampleDepsCacheClearResponseText,
    Route("/v1/reviews/refresh"): sampleReviewsRefreshResponseText,
    Route("/v1/reviews/comment"): sampleReviewsCommentResponseText,
    Route("/v1/reviews/avatar"): sampleReviewsAvatarResponseText,
    Route("/v1/reviews/body/update"): sampleReviewsBodyUpdateResponseText,
    Route("/v1/reviews/files/comment"): sampleReviewsFileCommentResponseText,
    Route("/v1/reviews/review-threads/resolve"):
      sampleReviewsReviewThreadResolveResponseText,
    Route("/v1/reviews/files/list"): sampleReviewsFilesListResponseText,
    Route("/v1/reviews/files/patch"): sampleReviewsFilesPatchResponseText,
    Route("/v1/reviews/files/preview"): sampleReviewsFilesPreviewResponseText,
    Route("/v1/reviews/files/viewed"): sampleReviewsFilesViewedResponseText,
    Route("/v1/reviews/files/blob"): sampleReviewsFilesBlobResponseText,
    Route("/v1/reviews/timeline"): sampleReviewsTimelineResponseText,
  ]

  static var records: [RecordedRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset() {
    lock.withLock { recordedRequests = [] }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.lock.withLock {
      Self.recordedRequests.append(
        RecordedRequest(
          path: url.path,
          query: url.query,
          method: request.httpMethod ?? "",
          body: Self.jsonBody(for: request)
        )
      )
    }
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )
    guard let response else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: Data(Self.responseBody(for: url.path, method: request.httpMethod ?? "").utf8)
    )
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func responseBody(for path: String, method: String) -> String {
    responseBodies[Route(path, method: method)]
      ?? responseBodies[Route(path)]
      ?? sampleTaskBoardItemJSONString
  }

  private static func jsonBody(for request: URLRequest) -> [String: Any]? {
    guard
      let data = bodyData(for: request),
      !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let body = object as? [String: Any]
    else {
      return nil
    }
    return body
  }

  private static func bodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return nil
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
