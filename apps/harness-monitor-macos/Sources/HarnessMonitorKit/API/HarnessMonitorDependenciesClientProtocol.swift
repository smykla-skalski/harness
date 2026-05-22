import Foundation

public protocol HarnessMonitorDependenciesClientProtocol: Sendable {
  func catalogDependencyUpdateRepositories(
    request: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse
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
  func refreshDependencyUpdates(
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse
  func fetchDependencyUpdateBody(
    request: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse
  func updateDependencyUpdateBody(
    request: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse
}

extension HarnessMonitorDependenciesClientProtocol {
  public func catalogDependencyUpdateRepositories(
    request _: DependencyUpdatesRepositoryCatalogRequest
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

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

  public func refreshDependencyUpdates(
    request _: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func fetchDependencyUpdateBody(
    request _: DependencyUpdatesBodyRequest
  ) async throws -> DependencyUpdatesBodyResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }

  public func updateDependencyUpdateBody(
    request _: DependencyUpdatesBodyUpdateRequest
  ) async throws -> DependencyUpdatesBodyUpdateResponse {
    throw HarnessMonitorAPIError.server(code: 501, message: "Dependencies unavailable")
  }
}
