import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performReviewsWebSocketContractCalls() async throws
    -> ReviewsWebSocketContractResult
  {
    let probe = RPCProbe()
    let transport = try makeReviewsWebSocketTransport(probe: probe)
    let target = reviewsWebSocketTarget()

    let actions = try await performReviewsActionCalls(transport: transport, target: target)
    let policy = try await performReviewsPolicyCalls(transport: transport, target: target)

    return ReviewsWebSocketContractResult(
      calls: await probe.calls,
      repositoryCatalog: actions.repositoryCatalog,
      capabilities: actions.capabilities,
      query: actions.query,
      preview: actions.preview,
      approve: actions.approve,
      merge: actions.merge,
      rerun: actions.rerun,
      label: actions.label,
      auto: actions.auto,
      policyPreview: policy.policyPreview,
      policyRun: policy.policyRun,
      policyStatus: policy.policyStatus,
      cacheClear: policy.cacheClear,
      refresh: policy.refresh,
      comment: policy.comment,
      avatar: policy.avatar,
      timeline: policy.timeline,
      resolve: policy.resolve
    )
  }

  private func performReviewsActionCalls(
    transport: WebSocketTransport,
    target: ReviewTarget
  ) async throws -> ReviewsWebSocketActionCalls {
    let repositoryCatalog = try await transport.catalogReviewRepositories(
      request: ReviewsRepositoryCatalogRequest(organization: "example")
    )
    let capabilities = try await transport.reviewsCapabilities()
    let query = try await transport.queryReviews(
      request: ReviewsQueryRequest(
        authors: ["renovate[bot]"],
        organizations: ["example"],
        repositories: ["example/harness"],
        excludeRepositories: ["example/archive"],
        forceRefresh: true,
        cacheMaxAgeSeconds: 120
      )
    )
    let preview = try await transport.previewReviewAction(
      request: ReviewsActionPreviewRequest(
        action: .merge,
        targets: [target],
        method: .rebase
      )
    )
    let approve = try await transport.approveReviews(
      request: ReviewsApproveRequest(targets: [target], source: .direct)
    )
    let merge = try await transport.mergeReviews(
      request: ReviewsMergeRequest(targets: [target], method: .rebase)
    )
    let rerun = try await transport.rerunReviewChecks(
      request: ReviewsRerunChecksRequest(targets: [target])
    )
    let label = try await transport.addReviewLabel(
      request: ReviewsLabelRequest(
        targets: [target],
        label: "dependencies:ready"
      )
    )
    let auto = try await transport.autoReviews(
      request: ReviewsAutoRequest(targets: [target], method: .squash)
    )
    return ReviewsWebSocketActionCalls(
      repositoryCatalog: repositoryCatalog,
      capabilities: capabilities,
      query: query,
      preview: preview,
      approve: approve,
      merge: merge,
      rerun: rerun,
      label: label,
      auto: auto
    )
  }

  private func performReviewsPolicyCalls(
    transport: WebSocketTransport,
    target: ReviewTarget
  ) async throws -> ReviewsWebSocketPolicyCalls {
    let policyPreview = try await transport.previewReviewsPolicy(
      ReviewsPolicyPreviewRequest(
        target: target,
        method: .squash
      )
    )
    let policyRun = try await transport.startReviewsPolicyRun(
      ReviewsPolicyRunStartRequest(
        target: target,
        method: .squash,
        trigger: .manual
      )
    )
    let policyStatus = try await transport.reviewsPolicyStatus(
      ReviewsPolicyStatusRequest(target: target)
    )
    let cacheClear = try await transport.clearReviewsCache()
    let refresh = try await transport.refreshReviews(
      request: ReviewsRefreshRequest(targets: [target])
    )
    let comment = try await transport.commentReviews(
      request: ReviewsCommentRequest(
        targets: [target],
        body: "@renovatebot rebase"
      )
    )
    let avatar = try await transport.fetchReviewAvatar(
      request: ReviewsAvatarRequest(
        avatarURL: "https://avatars.githubusercontent.com/in/2740?v=4"
      )
    )
    let timeline = try await transport.fetchReviewTimeline(
      request: ReviewsTimelineRequest(
        pullRequestId: target.pullRequestID,
        cursor: nil,
        pageSize: 50,
        direction: .older,
        forceRefresh: false,
        pullRequestUpdatedAt: "2026-05-21T09:00:00Z"
      )
    )
    let resolve = try await transport.resolveReviewPullRequests(
      request: ReviewsPullRequestResolveRequest(
        references: [ReviewsPullRequestReference(repository: "example/harness", number: 42)]
      )
    )
    return ReviewsWebSocketPolicyCalls(
      policyPreview: policyPreview,
      policyRun: policyRun,
      policyStatus: policyStatus,
      cacheClear: cacheClear,
      refresh: refresh,
      comment: comment,
      avatar: avatar,
      timeline: timeline,
      resolve: resolve
    )
  }

  func assertReviewsWebSocketRPCContract(_ calls: [RPCProbe.Call]) {
    #expect(
      calls.map(\.method)
        == [
          .reviewsRepositoryCatalog,
          .reviewsCapabilities,
          .reviewsQuery,
          .reviewsActionPreview,
          .reviewsApprove,
          .reviewsMerge,
          .reviewsRerunChecks,
          .reviewsAddLabel,
          .reviewsAuto,
          .reviewsPolicyPreview,
          .reviewsPolicyStart,
          .reviewsPolicyStatus,
          .reviewsClearCache,
          .reviewsRefresh,
          .reviewsComment,
          .reviewsAvatar,
          .reviewsTimeline,
          .reviewsPullRequestsResolve,
        ]
    )
  }

  func assertReviewsWebSocketPayloadContract(_ calls: [RPCProbe.Call]) {
    #expect(calls.count == 18)
    #expect(objectValue(calls[0].params, key: "organization") == .string("example"))
    #expect(calls[1].params == nil)
    #expect(objectValue(calls[2].params, key: "authors") == .array([.string("renovate[bot]")]))
    #expect(objectValue(calls[2].params, key: "organizations") == .array([.string("example")]))
    #expect(
      objectValue(calls[2].params, key: "repositories") == .array([.string("example/harness")]))
    #expect(
      objectValue(calls[2].params, key: "exclude_repositories")
        == .array([.string("example/archive")])
    )
    #expect(objectValue(calls[2].params, key: "force_refresh") == .bool(true))
    #expect(objectValue(calls[2].params, key: "cache_max_age_seconds") == .number(120))
    #expect(objectValue(calls[2].params, key: "backport_detection_enabled") == .bool(true))
    #expect(
      objectValue(calls[2].params, key: "backport_patterns")
        == .array(ReviewsQueryRequest.defaultBackportPatterns.map(JSONValue.string))
    )
    #expect(objectValue(calls[3].params, key: "action") == .string("merge"))
    #expect(
      objectValue(calls[3].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[3].params, key: "method") == .string("rebase"))
    #expect(
      objectValue(calls[4].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[4].params, key: "source") == .string("direct"))
    #expect(
      objectValue(calls[5].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[5].params, key: "method") == .string("rebase"))
    #expect(
      objectValue(calls[6].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(
      objectValue(calls[7].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[7].params, key: "label") == .string("dependencies:ready"))
    #expect(
      objectValue(calls[8].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[8].params, key: "method") == .string("squash"))
    #expect(objectValue(calls[9].params, key: "target") == .object(reviewsActionTargetJSON))
    #expect(objectValue(calls[9].params, key: "method") == .string("squash"))
    #expect(objectValue(calls[9].params, key: "workflow_id") == .string("reviews_auto"))
    #expect(objectValue(calls[10].params, key: "target") == .object(reviewsActionTargetJSON))
    #expect(objectValue(calls[10].params, key: "trigger") == .string("manual"))
    #expect(objectValue(calls[11].params, key: "workflow_id") == .string("reviews_auto"))
    #expect(
      objectValue(calls[11].params, key: "subject")
        == .object([
          "repository": .string("example/harness"),
          "pull_request_number": .number(42),
        ])
    )
    #expect(calls[12].params == nil)
    #expect(
      objectValue(calls[13].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[13].params, key: "backport_detection_enabled") == .bool(true))
    #expect(
      objectValue(calls[13].params, key: "backport_patterns")
        == .array(ReviewsQueryRequest.defaultBackportPatterns.map(JSONValue.string))
    )
    #expect(
      objectValue(calls[14].params, key: "targets")
        == .array([.object(reviewsActionTargetJSON)])
    )
    #expect(objectValue(calls[14].params, key: "body") == .string("@renovatebot rebase"))
    #expect(
      objectValue(calls[15].params, key: "avatar_url")
        == .string("https://avatars.githubusercontent.com/in/2740?v=4")
    )
    #expect(objectValue(calls[16].params, key: "pull_request_id") == .string("pr-42"))
    #expect(
      objectValue(calls[16].params, key: "pull_request_updated_at")
        == .string("2026-05-21T09:00:00Z")
    )
    #expect(objectValue(calls[16].params, key: "page_size") == .number(50))
    #expect(objectValue(calls[16].params, key: "direction") == .string("older"))
    assertReviewsWebSocketResolvePayload(calls[17])
  }

  func assertReviewsWebSocketResults(_ result: ReviewsWebSocketContractResult) {
    #expect(result.repositoryCatalog.organization == "example")
    #expect(result.capabilities.supportsActionPreview)
    #expect(result.repositoryCatalog.repositories == ["example/aff", "example/harness"])
    #expect(result.query.summary.total == 1)
    #expect(result.query.summary.autoApprovable == 1)
    #expect(result.query.items.first?.repository == "example/harness")
    #expect(result.query.items.first?.reviewStatus == .reviewRequired)
    #expect(result.preview.actionableCount == 1)
    #expect(result.approve.results.first?.action == .approve)
    #expect(result.merge.results.first?.action == .merge)
    #expect(result.rerun.results.first?.action == .rerunChecks)
    #expect(result.label.results.first?.action == .addLabel)
    #expect(result.auto.results.first?.action == .autoMerge)
    #expect(result.policyPreview.eligible)
    #expect(result.policyPreview.steps.count == 3)
    #expect(result.policyPreview.steps[1].stepType == .wait)
    #expect(result.policyRun.status == .waiting)
    #expect(result.policyRun.waitingOn?.eventKey == "reviews.checks_passed")
    #expect(result.policyStatus.activeRun?.runID == "run-42")
    #expect(result.policyStatus.recentRuns.count == 1)
    #expect(result.cacheClear.clearedEntries == 2)
    #expect(result.refresh.missingPullRequestIDs == ["pr-42"])
    #expect(result.comment.results.first?.action == .comment)
    #expect(result.comment.results.first?.timelineEntry?.id == "IC_comment_001")
    #expect(result.avatar.avatarURL == "https://avatars.githubusercontent.com/in/2740?v=4")
    #expect(result.avatar.mimeType == "image/png")
    #expect(result.timeline.pullRequestId == "pr-42")
    #expect(result.timeline.entries.first?.id == "IC_001")
    #expect(result.timeline.viewerCanComment)
    #expect(result.timeline.pageInfo.hasOlder)
    assertReviewsResolveResult(result.resolve)
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }

  private func reviewsWebSocketTarget() -> ReviewTarget {
    ReviewTarget(
      pullRequestID: "pr-42",
      repositoryID: "repo-1",
      repository: "example/harness",
      number: 42,
      url: "https://github.com/example/harness/pull/42",
      headSha: "abc123",
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      checkSuiteIDs: ["suite-1"]
    )
  }

  private func makeReviewsWebSocketTransport(probe: RPCProbe) throws -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        return try taskBoardRPCResponse(for: method)
      }
    )
  }
}

struct ReviewsWebSocketActionCalls {
  let repositoryCatalog: ReviewsRepositoryCatalogResponse
  let capabilities: ReviewsCapabilitiesResponse
  let query: ReviewsQueryResponse
  let preview: ReviewsActionPreviewResponse
  let approve: ReviewsActionResponse
  let merge: ReviewsActionResponse
  let rerun: ReviewsActionResponse
  let label: ReviewsActionResponse
  let auto: ReviewsActionResponse
}

struct ReviewsWebSocketPolicyCalls {
  let policyPreview: ReviewsPolicyPreviewResponse
  let policyRun: ReviewsPolicyRunResponse
  let policyStatus: ReviewsPolicyStatusResponse
  let cacheClear: ReviewsCacheClearResponse
  let refresh: ReviewsRefreshResponse
  let comment: ReviewsActionResponse
  let avatar: ReviewsAvatarResponse
  let timeline: ReviewsTimelineResponse
  let resolve: ReviewsPullRequestResolveResponse
}

struct ReviewsWebSocketContractResult {
  let calls: [RPCProbe.Call]
  let repositoryCatalog: ReviewsRepositoryCatalogResponse
  let capabilities: ReviewsCapabilitiesResponse
  let query: ReviewsQueryResponse
  let preview: ReviewsActionPreviewResponse
  let approve: ReviewsActionResponse
  let merge: ReviewsActionResponse
  let rerun: ReviewsActionResponse
  let label: ReviewsActionResponse
  let auto: ReviewsActionResponse
  let policyPreview: ReviewsPolicyPreviewResponse
  let policyRun: ReviewsPolicyRunResponse
  let policyStatus: ReviewsPolicyStatusResponse
  let cacheClear: ReviewsCacheClearResponse
  let refresh: ReviewsRefreshResponse
  let comment: ReviewsActionResponse
  let avatar: ReviewsAvatarResponse
  let timeline: ReviewsTimelineResponse
  let resolve: ReviewsPullRequestResolveResponse
}

private let reviewsTargetJSON: [String: JSONValue] = [
  "pull_request_id": .string("pr-42"),
  "repository_id": .string("repo-1"),
  "repository": .string("example/harness"),
  "number": .number(42),
  "url": .string("https://github.com/example/harness/pull/42"),
  "head_sha": .string("abc123"),
  "mergeable": .string("mergeable"),
  "review_status": .string("review_required"),
  "check_status": .string("success"),
  "policy_blocked": .bool(false),
  "check_suite_ids": .array([.string("suite-1")]),
]

// The action endpoints (approve/merge/rerun/label/auto/comment) encode their
// targets through ReviewTargetWire, which emits the full daemon shape rather
// than the hand encoder's default-omitting subset. The not-yet-rerouted
// preview/policy/refresh paths still send the minimal reviewsTargetJSON above.
private let reviewsActionTargetJSON: [String: JSONValue] = {
  var target = reviewsTargetJSON
  target["state"] = .string("open")
  target["is_draft"] = .bool(false)
  target["viewer_can_update"] = .bool(true)
  target["viewer_can_merge_as_admin"] = .bool(false)
  target["required_failed_check_names"] = .array([])
  return target
}()
