import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func assertReviewsHTTPRouteContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(
      records.map(\.method)
        == [
          "POST", "GET", "POST", "POST", "POST", "POST", "POST", "POST", "POST", "POST",
          "POST", "POST", "DELETE", "POST", "POST", "POST", "POST", "POST",
        ]
    )
    #expect(
      records.map(\.path)
        == [
          "/v1/reviews/repositories",
          "/v1/reviews/capabilities",
          "/v1/reviews/query",
          "/v1/reviews/action-preview",
          "/v1/reviews/approve",
          "/v1/reviews/merge",
          "/v1/reviews/rerun-checks",
          "/v1/reviews/labels",
          "/v1/reviews/auto",
          "/v1/reviews/policy/preview",
          "/v1/reviews/policy/start",
          "/v1/reviews/policy/status",
          "/v1/reviews/cache",
          "/v1/reviews/refresh",
          "/v1/reviews/comment",
          "/v1/reviews/avatar",
          "/v1/reviews/timeline",
          "/v1/reviews/pull-requests/resolve",
        ]
    )
  }

  func assertReviewsHTTPBodyContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(records[0].body?["organization"] as? String == "example")
    #expect(records[1].body == nil)
    #expect(records[2].body?["authors"] as? [String] == ["renovate[bot]"])
    #expect(records[2].body?["organizations"] as? [String] == ["example"])
    #expect(records[2].body?["repositories"] as? [String] == ["example/harness"])
    #expect(records[2].body?["exclude_repositories"] as? [String] == ["example/archive"])
    #expect(records[2].body?["force_refresh"] as? Bool == true)
    #expect(records[2].body?["cache_max_age_seconds"] as? Int == 120)
    #expect(records[2].body?["backport_detection_enabled"] as? Bool == true)
    #expect(
      records[2].body?["backport_patterns"] as? [String]
        == ReviewsQueryRequest.defaultBackportPatterns
    )
    #expect(records[3].body?["action"] as? String == "merge")
    #expect(records[3].body?["method"] as? String == "rebase")

    let approveTarget = (records[4].body?["targets"] as? [[String: Any]])?.first
    #expect(approveTarget?["pull_request_id"] as? String == "pr-42")
    #expect(approveTarget?["repository"] as? String == "example/harness")
    #expect(approveTarget?["check_suite_ids"] as? [String] == ["suite-1"])

    #expect(records[5].body?["method"] as? String == "rebase")
    #expect(records[6].body?["targets"] is [[String: Any]])
    #expect(records[7].body?["label"] as? String == "dependencies:ready")
    #expect(records[8].body?["method"] as? String == "squash")
    #expect(records[9].body?["workflow_id"] as? String == "reviews_auto")
    #expect(records[9].body?["method"] as? String == "squash")
    #expect(records[10].body?["trigger"] as? String == "manual")
    #expect(records[10].body?["workflow_id"] as? String == "reviews_auto")
    #expect(
      (records[11].body?["subject"] as? [String: Any])?["repository"] as? String
        == "example/harness")
    #expect((records[11].body?["subject"] as? [String: Any])?["pull_request_number"] as? Int == 42)
    #expect(records[12].body == nil)
    #expect(records[13].body?["backport_detection_enabled"] as? Bool == true)
    #expect(
      records[13].body?["backport_patterns"] as? [String]
        == ReviewsQueryRequest.defaultBackportPatterns
    )
    #expect(records[14].body?["body"] as? String == "@renovatebot rebase")
    #expect(records[14].body?["targets"] is [[String: Any]])
    #expect(
      records[15].body?["avatar_url"] as? String
        == "https://avatars.githubusercontent.com/in/2740?v=4"
    )
    #expect(records[16].body?["pull_request_id"] as? String == "pr-42")
    #expect(
      records[16].body?["pull_request_updated_at"] as? String
        == "2026-05-21T09:00:00Z"
    )
    #expect(records[16].body?["page_size"] as? Int == 50)
    #expect(records[16].body?["direction"] as? String == "older")
    let resolveReference = (records[17].body?["references"] as? [[String: Any]])?.first
    #expect(resolveReference?["repository"] as? String == "example/harness")
    #expect(resolveReference?["number"] as? Int == 42)
    #expect(records[17].body?["backport_detection_enabled"] as? Bool == true)
    #expect(
      records[17].body?["backport_patterns"] as? [String]
        == ReviewsQueryRequest.defaultBackportPatterns
    )
  }

  func assertHTTPClientResults(_ result: TaskBoardHTTPContractResult) {
    #expect(result.planning.transition.boardItemId == "board-1")
    #expect(result.planning.transition.toStatus == .planReview)
    #expect(result.sync.providers.first?.provider == .gitHub)
    #expect(result.sync.operations.first?.action == .push)
    #expect(result.sync.operations.first?.boardItemId == "board-1")
    #expect(result.sync.operations.first?.applied == true)
    #expect(result.dispatch.plans.first?.task.title == "Board item")
    #expect(result.dispatch.plans.first?.policy?.decision == "allow")
    #expect(result.dispatch.applied.first?.workItemId == "task-1")
    #expect(result.dispatch.applied.first?.item.workflow?.prNumber == 42)
    #expect(result.evaluation.records.first?.outcome == .completed)
    #expect(result.evaluation.updated == 1)
    #expect(result.status.currentTick?.phase == .evaluation)
    #expect(result.status.lastRun?.evaluation?.completed == 1)
    #expect(result.status.lastRun?.policyTraceIds == ["trace-1"])
    #expect(result.status.workflowExecutionCounts.first?.status == .completed)
    #expect(result.status.workflowExecutionCounts.first?.count == 3)
    #expect(result.runOnce.lastRun?.evaluation?.updated == 1)
    #expect(result.runOnce.lastRun?.policyTraceIds == ["trace-1"])
    #expect(result.runOnce.lastRun?.dispatch?.applied.first?.workItemId == "task-1")
    #expect(result.updatedSettings.githubInbox.repositories == ["example/harness", "example/aff"])
    #expect(result.updatedSettings.policyVersion == "task-board-policy-v2")
    #expect(result.runtimeConfig.global.authorName == "Harness Bot")
    #expect(result.updatedRuntimeConfig.repositoryOverrides.first?.repository == "example/harness")
    #expect(result.tokenSync.globalTokenConfigured == true)
    #expect(result.tokenSync.repositoryTokenCount == 1)
    #expect(result.todoistTokenSync.tokenConfigured == true)
  }

  func assertReviewsHTTPClientResults(_ result: ReviewsHTTPContractResult) {
    #expect(result.repositoryCatalog.organization == "example")
    #expect(result.capabilities.supportsActionPreview)
    #expect(result.repositoryCatalog.repositories == ["example/aff", "example/harness"])
    #expect(result.query.summary.total == 1)
    #expect(result.query.summary.autoApprovable == 1)
    #expect(result.query.items.first?.repository == "example/harness")
    #expect(result.query.items.first?.reviewStatus == .reviewRequired)
    #expect(result.preview.actionableCount == 1)
    #expect(
      result.query.items.first?.checks.first?.detailsURL
        == "https://github.com/example/harness/actions/runs/1001/job/2002"
    )
    #expect(
      result.query.items.first?.checks.map(\.detailsURL)
        == [
          "https://github.com/example/harness/actions/runs/1001/job/2002",
          "https://ci.example.com/example/harness/builds/42",
        ]
    )
    #expect(result.approve.results.first?.action == .approve)
    #expect(result.merge.results.first?.action == .merge)
    #expect(result.rerun.results.first?.action == .rerunChecks)
    #expect(result.label.results.first?.action == .addLabel)
    #expect(result.auto.results.first?.action == .autoMerge)
    #expect(result.policyPreview.eligible)
    #expect(result.policyPreview.steps.count == 3)
    #expect(result.policyPreview.steps[1].stepType == .wait)
    #expect(result.policyPreview.steps[1].waitingOn?.eventKey == "reviews.checks_passed")
    #expect(result.policyRun.status == .waiting)
    #expect(result.policyRun.waitingOn?.eventKey == "reviews.checks_passed")
    #expect(result.policyRun.steps.first?.actionKey == "reviews.approve")
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
    #expect(result.resolve.items.first?.pullRequestID == "pr-42")
    #expect(
      result.resolve.missingReferences
        == [ReviewsPullRequestReference(repository: "example/missing", number: 404)]
    )
  }

  func makeClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskBoardURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: session
    )
  }

  func reviewsTarget() -> ReviewTarget {
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
}

struct ReviewsHTTPContractResult {
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
