import AppIntents
import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class TaskBoardIntentTests: XCTestCase {
  func testListTaskBoardItemsForwardsStatusFilterToSource() async throws {
    let stub = StubTaskBoardItemSource(
      listResult: [
        Self.makeItem(id: "task-1", title: "Pick up", status: .needsYou)
      ]
    )
    let intent = ListTaskBoardItemsIntent(status: .needsYou, source: stub)

    let entities = try await intent.resolveEntities()

    XCTAssertEqual(entities.map(\.id), ["task-1"])
    XCTAssertEqual(entities.first?.status, .needsYou)
    let recorded = await stub.recordedListFilters
    XCTAssertEqual(recorded, [TaskBoardStatus.needsYou])
  }

  func testListTaskBoardItemsReturnsEverythingWhenStatusNil() async throws {
    let stub = StubTaskBoardItemSource(
      listResult: [
        Self.makeItem(id: "task-1", title: "A", status: .todo),
        Self.makeItem(id: "task-2", title: "B", status: .inProgress)
      ]
    )
    let intent = ListTaskBoardItemsIntent(status: nil, source: stub)

    let entities = try await intent.resolveEntities()

    XCTAssertEqual(entities.map(\.id), ["task-1", "task-2"])
    let recorded = await stub.recordedListFilters
    XCTAssertEqual(recorded, [nil] as [TaskBoardStatus?])
  }

  func testDispatchForwardsItemIDToSource() async throws {
    let stub = StubTaskBoardItemSource()
    let intent = DispatchTaskIntent(
      item: Self.makeEntity(id: "task-42", title: "Run me"),
      source: stub
    )

    try await intent.applyDispatch()

    let recorded = await stub.recordedDispatches
    XCTAssertEqual(recorded, ["task-42"])
  }

  func testApprovePlanForwardsIDAndApproverToSource() async throws {
    let stub = StubTaskBoardItemSource()
    let intent = ApproveTaskBoardPlanIntent(
      item: Self.makeEntity(id: "task-7", title: "Approve me"),
      source: stub,
      approver: "alice"
    )

    try await intent.applyApproval()

    let recorded = await stub.recordedApprovals
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.itemID, "task-7")
    XCTAssertEqual(recorded.first?.approver, "alice")
  }

  func testOpenTaskBoardWithoutItemTargetsBoardRoot() {
    let url = HarnessMonitorDeepLinkRouter.url(for: .taskBoard(itemID: nil))

    XCTAssertEqual(url, URL(string: "harness://taskboard"))
  }

  func testOpenTaskBoardWithItemTargetsItemPath() {
    let url = HarnessMonitorDeepLinkRouter.url(for: .taskBoard(itemID: "task-9"))

    XCTAssertEqual(url, URL(string: "harness://taskboard/task-9"))
  }

  func testTaskBoardStatusEnumRoundTripsWithDaemonValues() {
    for daemon in TaskBoardStatus.allCases {
      let wrapped = TaskBoardStatusEnum(daemonValue: daemon)
      XCTAssertEqual(wrapped.daemonValue, daemon)
    }
  }

  // MARK: - helpers

  private static func makeEntity(id: String, title: String) -> TaskBoardItemEntity {
    TaskBoardItemEntity(
      id: id,
      title: title,
      status: .todo,
      priority: "Medium",
      projectId: nil
    )
  }

  private static func makeItem(id: String, title: String, status: TaskBoardStatus)
    -> TaskBoardItem
  {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-23T10:00:00Z",
      updatedAt: "2026-05-23T12:00:00Z",
      deletedAt: nil
    )
  }
}

actor StubTaskBoardItemSource: TaskBoardItemSource {
  private let listResult: [TaskBoardItem]
  private let searchResult: [TaskBoardItem]
  private(set) var recordedListFilters: [TaskBoardStatus?] = []
  private(set) var recordedDispatches: [String] = []
  private(set) var recordedApprovals: [(itemID: String, approver: String)] = []

  init(listResult: [TaskBoardItem] = [], searchResult: [TaskBoardItem] = []) {
    self.listResult = listResult
    self.searchResult = searchResult
  }

  func fetch(ids: [String]) async throws -> [TaskBoardItem] {
    listResult.filter { ids.contains($0.id) }
  }

  func list(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    recordedListFilters.append(status)
    return listResult
  }

  func search(query: String) async throws -> [TaskBoardItem] {
    searchResult
  }

  func dispatch(itemID: String) async throws {
    recordedDispatches.append(itemID)
  }

  func approvePlan(itemID: String, approver: String) async throws {
    recordedApprovals.append((itemID, approver))
  }
}
