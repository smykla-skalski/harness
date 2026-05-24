import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class TaskBoardItemQueryTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "io.harnessmonitor.test.taskboardquery.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    suiteName = nil
    super.tearDown()
  }

  private func makeRecorder() -> IntentDonationRecorder {
    IntentDonationRecorder(
      capacity: 20,
      defaults: UserDefaults(suiteName: suiteName),
      storageKey: "test-donations"
    )
  }

  func testSuggestedEntitiesReturnsItemsFromSource() async throws {
    let stub = StubTaskBoardItemSource(
      listResult: [
        Self.makeItem(id: "task-1", title: "A", status: .todo),
        Self.makeItem(id: "task-2", title: "B", status: .inProgress)
      ]
    )
    let query = TaskBoardItemQuery(source: stub, donationRecorder: makeRecorder())

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["task-1", "task-2"])
  }

  func testSuggestedEntitiesBumpsRecentlyDonatedItemsToFront() async throws {
    let donated = Self.makeItem(id: "task-42", title: "Donated", status: .needsYou)
    let other = Self.makeItem(id: "task-43", title: "Other", status: .todo)
    let stub = StubTaskBoardItemSource(listResult: [other, donated])
    let recorder = makeRecorder()
    await recorder.recordDonation(kind: .taskBoardItem, id: donated.id)
    let query = TaskBoardItemQuery(source: stub, donationRecorder: recorder)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(
      result.map(\.id),
      ["task-42", "task-43"],
      "donated task should move to the front while the rest keep daemon order"
    )
  }

  func testSuggestedEntitiesPreservesOrderWithoutDonations() async throws {
    let first = Self.makeItem(id: "task-1", title: "First", status: .todo)
    let second = Self.makeItem(id: "task-2", title: "Second", status: .todo)
    let stub = StubTaskBoardItemSource(listResult: [first, second])
    let query = TaskBoardItemQuery(source: stub, donationRecorder: makeRecorder())

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["task-1", "task-2"])
  }

  func testSuggestedEntitiesIgnoresPullRequestKindDonations() async throws {
    let first = Self.makeItem(id: "task-1", title: "First", status: .todo)
    let second = Self.makeItem(id: "task-2", title: "Second", status: .todo)
    let stub = StubTaskBoardItemSource(listResult: [first, second])
    let recorder = makeRecorder()
    await recorder.recordDonation(kind: .pullRequest, id: "task-2")
    let query = TaskBoardItemQuery(source: stub, donationRecorder: recorder)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(
      result.map(\.id),
      ["task-1", "task-2"],
      "a PR-kind donation must not bias the task-board surface"
    )
  }

  // MARK: - helpers

  private static func makeItem(
    id: String, title: String, status: TaskBoardStatus
  ) -> TaskBoardItem {
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
