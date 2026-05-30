import XCTest

@testable import HarnessMonitorKit

@MainActor
final class TaskBoardPolicyCanvasStoreTests: XCTestCase {
  func testRefreshLoadsActiveCanvasWorkspaceSnapshot() async throws {
    let client = RecordingHarnessClient()
    _ = try await client.createTaskBoardPolicyCanvas(
      request: TaskBoardPolicyCanvasCreateRequest(title: "Release Policies")
    )
    let expectedWorkspace = try await client.taskBoardPolicyCanvasWorkspace()

    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    XCTAssertEqual(store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace, expectedWorkspace)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Release Policies")
    XCTAssertGreaterThanOrEqual(client.readCallCount(.taskBoardPolicyCanvasWorkspace), 2)
  }

  func testCanvasMutationsReloadActiveSnapshotAndKeepGuards() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    await store.refreshTaskBoardPolicyPipeline()
    let originalCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId
    )

    let created = await store.createTaskBoardPolicyCanvas(title: "Escalations")
    XCTAssertTrue(created)
    let createdCanvasID = try XCTUnwrap(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId
    )
    XCTAssertNotEqual(createdCanvasID, originalCanvasID)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Escalations")

    var updatedDocument = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyPipeline)
    updatedDocument.revision += 1
    let saved = await store.saveTaskBoardPolicyPipelineDraft(document: updatedDocument)
    XCTAssertNotNil(saved)
    XCTAssertEqual(client.recordedSavedTaskBoardPolicyCanvasIDs().last ?? nil, createdCanvasID)

    let simulated = await store.simulateTaskBoardPolicyPipeline()
    XCTAssertTrue(simulated)
    XCTAssertEqual(client.recordedSimulatedTaskBoardPolicyCanvasIDs().last ?? nil, createdCanvasID)

    let promoted = await store.promoteTaskBoardPolicyPipeline(revision: updatedDocument.revision)
    XCTAssertTrue(promoted)
    XCTAssertEqual(client.recordedPromotedTaskBoardPolicyCanvasIDs().last ?? nil, createdCanvasID)

    let reactivated = await store.activateTaskBoardPolicyCanvas(canvasId: originalCanvasID)
    XCTAssertTrue(reactivated)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
      originalCanvasID
    )
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyPipeline?.nodes.first?.title, "Policy Canvas 1")
  }
}
