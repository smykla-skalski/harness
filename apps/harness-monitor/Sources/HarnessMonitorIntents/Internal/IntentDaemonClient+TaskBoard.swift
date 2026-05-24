import Foundation
import HarnessMonitorKit

extension IntentDaemonClient {
  public func fetchTaskBoardItems(ids: [String]) async throws -> [TaskBoardItem] {
    guard !ids.isEmpty else { return [] }
    let lookup = Set(ids)
    let response = try await listTaskBoardItems(status: nil)
    let byID = Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0) })
    return ids.compactMap { byID[$0] }.filter { lookup.contains($0.id) }
  }

  public func listTaskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    do {
      try await ensureConnected()
      return try await transport.taskBoardItems(status: status)
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.list",
        message: error.localizedDescription
      )
    }
  }

  public func searchTaskBoardItems(query: String) async throws -> [TaskBoardItem] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }
    let items = try await listTaskBoardItems(status: nil)
    return items.filter { item in
      item.title.lowercased().contains(needle)
        || item.body.lowercased().contains(needle)
        || (item.projectId?.lowercased().contains(needle) ?? false)
    }
  }

  public func dispatchTaskBoardItem(itemID: String) async throws {
    let trimmed = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.dispatch",
        message: "Task ID must not be blank"
      )
    }
    do {
      try await ensureConnected()
      _ = try await transport.dispatchTaskBoard(
        request: TaskBoardDispatchRequest(itemId: trimmed, dryRun: false)
      )
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.dispatch",
        message: error.localizedDescription
      )
    }
  }

  public func approveTaskBoardItemPlan(itemID: String, approver: String) async throws {
    let trimmedID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedApprover = approver.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.plan_approve",
        message: "Task ID must not be blank"
      )
    }
    guard !trimmedApprover.isEmpty else {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.plan_approve",
        message: "Approver must not be blank"
      )
    }
    do {
      try await ensureConnected()
      _ = try await transport.approveTaskBoardPlan(
        id: trimmedID,
        request: TaskBoardPlanApproveRequest(approvedBy: trimmedApprover)
      )
    } catch {
      throw IntentDaemonError.rpcFailed(
        method: "task_board.plan_approve",
        message: error.localizedDescription
      )
    }
  }
}
