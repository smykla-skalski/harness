import Foundation
import HarnessMonitorKit

public enum MobileRelayClientProviderError: Error, Equatable, CustomStringConvertible,
  Sendable
{
  case clientUnavailable

  public var description: String {
    switch self {
    case .clientUnavailable:
      "Harness daemon client is unavailable."
    }
  }
}

public struct HarnessMonitorClientProviderMobileRelayCommandClient: MobileRelayCommandClient {
  private let clientProvider: @Sendable () async -> (any HarnessMonitorClientProtocol)?

  public init(
    clientProvider: @escaping @Sendable () async -> (any HarnessMonitorClientProtocol)?
  ) {
    self.clientProvider = clientProvider
  }

  public func resolveAcpPermission(
    agentID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async throws -> String {
    try await commandClient().resolveAcpPermission(
      agentID: agentID,
      batchID: batchID,
      decision: decision
    )
  }

  public func dispatchTaskBoard(_ request: TaskBoardDispatchRequest) async throws -> String {
    try await commandClient().dispatchTaskBoard(request)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> String {
    try await commandClient().approveTaskBoardPlan(id: id, request: request)
  }

  public func startAgent(
    sessionID: String,
    request: MobileRelayAgentStartRequest
  ) async throws -> String {
    try await commandClient().startAgent(sessionID: sessionID, request: request)
  }

  public func stopAgent(agentID: String) async throws -> String {
    try await commandClient().stopAgent(agentID: agentID)
  }

  public func promptAgent(agentID: String, prompt: String) async throws -> String {
    try await commandClient().promptAgent(agentID: agentID, prompt: prompt)
  }

  public func approvePullRequest(_ target: ReviewTarget) async throws -> String {
    try await commandClient().approvePullRequest(target)
  }

  public func labelPullRequest(_ target: ReviewTarget, label: String) async throws -> String {
    try await commandClient().labelPullRequest(target, label: label)
  }

  public func rerunPullRequestChecks(_ target: ReviewTarget) async throws -> String {
    try await commandClient().rerunPullRequestChecks(target)
  }

  public func mergePullRequest(
    _ target: ReviewTarget,
    method: TaskBoardGitHubMergeMethod
  ) async throws -> String {
    try await commandClient().mergePullRequest(target, method: method)
  }

  public func refresh(scope: MobileRelayRefreshScope, target: ReviewTarget?) async throws
    -> String
  {
    try await commandClient().refresh(scope: scope, target: target)
  }

  private func commandClient() async throws -> HarnessMonitorClientMobileRelayCommandClient {
    guard let client = await clientProvider() else {
      throw MobileRelayClientProviderError.clientUnavailable
    }
    return HarnessMonitorClientMobileRelayCommandClient(client: client)
  }
}
