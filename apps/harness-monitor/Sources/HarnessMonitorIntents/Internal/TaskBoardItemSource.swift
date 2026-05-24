import Foundation
import HarnessMonitorKit

public protocol TaskBoardItemSource: Sendable {
  func fetch(ids: [String]) async throws -> [TaskBoardItem]
  func list(status: TaskBoardStatus?) async throws -> [TaskBoardItem]
  func search(query: String) async throws -> [TaskBoardItem]
  func dispatch(itemID: String) async throws
  func approvePlan(itemID: String, approver: String) async throws
}

struct DaemonTaskBoardItemSource: TaskBoardItemSource {
  let environment: HarnessMonitorEnvironment
  let cache: IntentDaemonClientCache

  init(
    environment: HarnessMonitorEnvironment = .current,
    cache: IntentDaemonClientCache = .shared
  ) {
    self.environment = environment
    self.cache = cache
  }

  func fetch(ids: [String]) async throws -> [TaskBoardItem] {
    try await runRPC { client in
      try await client.fetchTaskBoardItems(ids: ids)
    }
  }

  func list(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    try await runRPC { client in
      try await client.listTaskBoardItems(status: status)
    }
  }

  func search(query: String) async throws -> [TaskBoardItem] {
    try await runRPC { client in
      try await client.searchTaskBoardItems(query: query)
    }
  }

  func dispatch(itemID: String) async throws {
    try await runRPC { client in
      try await client.dispatchTaskBoardItem(itemID: itemID)
    }
  }

  func approvePlan(itemID: String, approver: String) async throws {
    try await runRPC { client in
      try await client.approveTaskBoardItemPlan(itemID: itemID, approver: approver)
    }
  }

  private func runRPC<T: Sendable>(
    _ body: @Sendable (IntentDaemonClient) async throws -> T
  ) async throws -> T {
    let client = try await cache.client(for: environment)
    do {
      return try await body(client)
    } catch {
      await cache.invalidate()
      throw error
    }
  }
}
