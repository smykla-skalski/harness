import Foundation
import HarnessMonitorKit

public protocol RepositorySource: Sendable {
  func suggested() async throws -> [String]
  func search(query: String) async throws -> [String]
}

struct DaemonRepositorySource: RepositorySource {
  let environment: HarnessMonitorEnvironment
  let cache: IntentDaemonClientCache

  init(
    environment: HarnessMonitorEnvironment = .current,
    cache: IntentDaemonClientCache = .shared
  ) {
    self.environment = environment
    self.cache = cache
  }

  func suggested() async throws -> [String] {
    let client = try await cache.client(for: environment)
    do {
      return try await client.suggestedRepositoryIDs()
    } catch {
      await cache.invalidate()
      throw error
    }
  }

  func search(query: String) async throws -> [String] {
    let client = try await cache.client(for: environment)
    do {
      return try await client.searchRepositoryIDs(query: query)
    } catch {
      await cache.invalidate()
      throw error
    }
  }
}
