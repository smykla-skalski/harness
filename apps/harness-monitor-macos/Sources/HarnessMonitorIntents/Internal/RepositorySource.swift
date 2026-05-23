import Foundation
import HarnessMonitorKit

public protocol RepositorySource: Sendable {
  func suggested() async throws -> [String]
  func search(query: String) async throws -> [String]
}

struct DaemonRepositorySource: RepositorySource {
  let environment: HarnessMonitorEnvironment

  init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  func suggested() async throws -> [String] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.suggestedRepositoryIDs()
  }

  func search(query: String) async throws -> [String] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.searchRepositoryIDs(query: query)
  }
}
