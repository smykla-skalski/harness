import Foundation

public protocol HarnessMonitorDependenciesClientProtocol: Sendable {
  func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse
  func approveDependencyUpdates(
    request: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse
  func mergeDependencyUpdates(
    request: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse
  func rerunDependencyUpdateChecks(
    request: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse
  func addDependencyUpdateLabel(
    request: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse
  func autoDependencyUpdates(
    request: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse
  func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse
}

extension HarnessMonitorDependenciesClientProtocol {
  public func queryDependencyUpdates(
    request _: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func approveDependencyUpdates(
    request _: DependencyUpdatesApproveRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func mergeDependencyUpdates(
    request _: DependencyUpdatesMergeRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func rerunDependencyUpdateChecks(
    request _: DependencyUpdatesRerunChecksRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func addDependencyUpdateLabel(
    request _: DependencyUpdatesLabelRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func autoDependencyUpdates(
    request _: DependencyUpdatesAutoRequest
  ) async throws -> DependencyUpdatesActionResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func clearDependencyUpdatesCache() async throws -> DependencyUpdatesCacheClearResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }
}
