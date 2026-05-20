import Foundation
import Testing

@testable import HarnessMonitorKit

extension TaskBoardAPIClientTests {
  func performDependencyUpdatesWebSocketContractCalls() async throws
    -> DependencyUpdatesWebSocketContractResult
  {
    let probe = RPCProbe()
    let transport = WebSocketTransport(
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
    let target = dependencyUpdatesWebSocketTarget()

    let repositoryCatalog = try await transport.catalogDependencyUpdateRepositories(
      request: DependencyUpdatesRepositoryCatalogRequest(organization: "example")
    )
    let query = try await transport.queryDependencyUpdates(
      request: DependencyUpdatesQueryRequest(
        authors: ["renovate[bot]"],
        organizations: ["example"],
        repositories: ["example/harness"],
        excludeRepositories: ["example/archive"],
        forceRefresh: true,
        cacheMaxAgeSeconds: 120
      )
    )
    let approve = try await transport.approveDependencyUpdates(
      request: DependencyUpdatesApproveRequest(targets: [target])
    )
    let merge = try await transport.mergeDependencyUpdates(
      request: DependencyUpdatesMergeRequest(targets: [target], method: .rebase)
    )
    let rerun = try await transport.rerunDependencyUpdateChecks(
      request: DependencyUpdatesRerunChecksRequest(targets: [target])
    )
    let label = try await transport.addDependencyUpdateLabel(
      request: DependencyUpdatesLabelRequest(
        targets: [target],
        label: "dependencies:ready"
      )
    )
    let auto = try await transport.autoDependencyUpdates(
      request: DependencyUpdatesAutoRequest(targets: [target], method: .squash)
    )
    let cacheClear = try await transport.clearDependencyUpdatesCache()

    return DependencyUpdatesWebSocketContractResult(
      calls: await probe.calls,
      repositoryCatalog: repositoryCatalog,
      query: query,
      approve: approve,
      merge: merge,
      rerun: rerun,
      label: label,
      auto: auto,
      cacheClear: cacheClear
    )
  }

  func assertDependencyUpdatesWebSocketRPCContract(_ calls: [RPCProbe.Call]) {
    #expect(
      calls.map(\.method)
        == [
          .dependencyUpdatesRepositoryCatalog,
          .dependencyUpdatesQuery,
          .dependencyUpdatesApprove,
          .dependencyUpdatesMerge,
          .dependencyUpdatesRerunChecks,
          .dependencyUpdatesAddLabel,
          .dependencyUpdatesAuto,
          .dependencyUpdatesClearCache,
        ]
    )
  }

  func assertDependencyUpdatesWebSocketPayloadContract(_ calls: [RPCProbe.Call]) {
    #expect(calls.count == 8)
    #expect(objectValue(calls[0].params, key: "organization") == .string("example"))
    #expect(objectValue(calls[1].params, key: "authors") == .array([.string("renovate[bot]")]))
    #expect(objectValue(calls[1].params, key: "organizations") == .array([.string("example")]))
    #expect(objectValue(calls[1].params, key: "repositories") == .array([.string("example/harness")]))
    #expect(
      objectValue(calls[1].params, key: "exclude_repositories")
        == .array([.string("example/archive")])
    )
    #expect(objectValue(calls[1].params, key: "force_refresh") == .bool(true))
    #expect(objectValue(calls[1].params, key: "cache_max_age_seconds") == .number(120))
    #expect(
      objectValue(calls[2].params, key: "targets")
        == .array([.object(dependencyUpdatesTargetJSON)])
    )
    #expect(
      objectValue(calls[3].params, key: "targets")
        == .array([.object(dependencyUpdatesTargetJSON)])
    )
    #expect(objectValue(calls[3].params, key: "method") == .string("rebase"))
    #expect(
      objectValue(calls[4].params, key: "targets")
        == .array([.object(dependencyUpdatesTargetJSON)])
    )
    #expect(
      objectValue(calls[5].params, key: "targets")
        == .array([.object(dependencyUpdatesTargetJSON)])
    )
    #expect(objectValue(calls[5].params, key: "label") == .string("dependencies:ready"))
    #expect(
      objectValue(calls[6].params, key: "targets")
        == .array([.object(dependencyUpdatesTargetJSON)])
    )
    #expect(objectValue(calls[6].params, key: "method") == .string("squash"))
    #expect(calls[7].params == nil)
  }

  func assertDependencyUpdatesWebSocketResults(_ result: DependencyUpdatesWebSocketContractResult) {
    #expect(result.repositoryCatalog.organization == "example")
    #expect(result.repositoryCatalog.repositories == ["example/aff", "example/harness"])
    #expect(result.query.summary.total == 1)
    #expect(result.query.summary.autoApprovable == 1)
    #expect(result.query.items.first?.repository == "example/harness")
    #expect(result.query.items.first?.reviewStatus == .reviewRequired)
    #expect(result.approve.results.first?.action == .approve)
    #expect(result.merge.results.first?.action == .merge)
    #expect(result.rerun.results.first?.action == .rerunChecks)
    #expect(result.label.results.first?.action == .addLabel)
    #expect(result.auto.results.first?.action == .autoMerge)
    #expect(result.cacheClear.clearedEntries == 2)
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }

  private func dependencyUpdatesWebSocketTarget() -> DependencyUpdateTarget {
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

struct DependencyUpdatesWebSocketContractResult {
  let calls: [RPCProbe.Call]
  let repositoryCatalog: DependencyUpdatesRepositoryCatalogResponse
  let query: DependencyUpdatesQueryResponse
  let approve: DependencyUpdatesActionResponse
  let merge: DependencyUpdatesActionResponse
  let rerun: DependencyUpdatesActionResponse
  let label: DependencyUpdatesActionResponse
  let auto: DependencyUpdatesActionResponse
  let cacheClear: DependencyUpdatesCacheClearResponse
}

private let dependencyUpdatesTargetJSON: [String: JSONValue] = [
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
