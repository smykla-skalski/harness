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

  init(environment: HarnessMonitorEnvironment = .current) {
    self.environment = environment
  }

  func fetch(ids: [String]) async throws -> [TaskBoardItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.fetchTaskBoardItems(ids: ids)
  }

  func list(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.listTaskBoardItems(status: status)
  }

  func search(query: String) async throws -> [TaskBoardItem] {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    return try await client.searchTaskBoardItems(query: query)
  }

  func dispatch(itemID: String) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.dispatchTaskBoardItem(itemID: itemID)
  }

  func approvePlan(itemID: String, approver: String) async throws {
    let client = try IntentDaemonClient.resolveFromEnvironment(environment: environment)
    try await client.approveTaskBoardItemPlan(itemID: itemID, approver: approver)
  }
}
