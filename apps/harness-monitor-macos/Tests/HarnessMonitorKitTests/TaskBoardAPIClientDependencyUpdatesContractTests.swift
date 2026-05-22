import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func assertDependencyUpdatesHTTPRouteContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(
      records.map(\.method)
        == ["POST", "POST", "POST", "POST", "POST", "POST", "POST", "DELETE", "POST"]
    )
    #expect(
      records.map(\.path)
        == [
          "/v1/dependency-updates/repositories",
          "/v1/dependency-updates/query",
          "/v1/dependency-updates/approve",
          "/v1/dependency-updates/merge",
          "/v1/dependency-updates/rerun-checks",
          "/v1/dependency-updates/labels",
          "/v1/dependency-updates/auto",
          "/v1/dependency-updates/cache",
          "/v1/dependency-updates/refresh",
        ]
    )
  }

  func assertDependencyUpdatesHTTPBodyContract(_ records: [TaskBoardURLProtocol.RecordedRequest]) {
    #expect(records[0].body?["organization"] as? String == "example")
    #expect(records[1].body?["authors"] as? [String] == ["renovate[bot]"])
    #expect(records[1].body?["organizations"] as? [String] == ["example"])
    #expect(records[1].body?["repositories"] as? [String] == ["example/harness"])
    #expect(records[1].body?["exclude_repositories"] as? [String] == ["example/archive"])
    #expect(records[1].body?["force_refresh"] as? Bool == true)
    #expect(records[1].body?["cache_max_age_seconds"] as? Int == 120)

    let approveTarget = (records[2].body?["targets"] as? [[String: Any]])?.first
    #expect(approveTarget?["pull_request_id"] as? String == "pr-42")
    #expect(approveTarget?["repository"] as? String == "example/harness")
    #expect(approveTarget?["check_suite_ids"] as? [String] == ["suite-1"])

    #expect(records[3].body?["method"] as? String == "rebase")
    #expect(records[4].body?["targets"] is [[String: Any]])
    #expect(records[5].body?["label"] as? String == "dependencies:ready")
    #expect(records[6].body?["method"] as? String == "squash")
    #expect(records[7].body == nil)
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

  func assertDependencyUpdatesHTTPClientResults(_ result: DependencyUpdatesHTTPContractResult) {
    #expect(result.repositoryCatalog.organization == "example")
    #expect(result.repositoryCatalog.repositories == ["example/aff", "example/harness"])
    #expect(result.query.summary.total == 1)
    #expect(result.query.summary.autoApprovable == 1)
    #expect(result.query.items.first?.repository == "example/harness")
    #expect(result.query.items.first?.reviewStatus == .reviewRequired)
    #expect(
      result.query.items.first?.checks.first?.detailsURL
        == "https://github.com/example/harness/actions/runs/1001/job/2002"
    )
    #expect(result.approve.results.first?.action == .approve)
    #expect(result.merge.results.first?.action == .merge)
    #expect(result.rerun.results.first?.action == .rerunChecks)
    #expect(result.label.results.first?.action == .addLabel)
    #expect(result.auto.results.first?.action == .autoMerge)
    #expect(result.cacheClear.clearedEntries == 2)
    #expect(result.refresh.missingPullRequestIDs == ["pr-42"])
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

  func dependencyUpdatesTarget() -> DependencyUpdateTarget {
    DependencyUpdateTarget(
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

struct DependencyUpdatesHTTPContractResult {
  let repositoryCatalog: DependencyUpdatesRepositoryCatalogResponse
  let query: DependencyUpdatesQueryResponse
  let approve: DependencyUpdatesActionResponse
  let merge: DependencyUpdatesActionResponse
  let rerun: DependencyUpdatesActionResponse
  let label: DependencyUpdatesActionResponse
  let auto: DependencyUpdatesActionResponse
  let cacheClear: DependencyUpdatesCacheClearResponse
  let refresh: DependencyUpdatesRefreshResponse
}
