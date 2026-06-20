import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

extension TaskBoardPolicyCanvasStoreTests {
  func testScenarioCreateUpdateDeleteRoundTripsThroughWorkspace() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    let created = await store.createTaskBoardPolicyScenario(
      name: "Merge - checks green",
      input: PolicyInput(action: .mergePr)
    )
    XCTAssertTrue(created)
    var scenarios = try XCTUnwrap(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.scenarios
    )
    XCTAssertEqual(scenarios.count, 1)
    XCTAssertEqual(scenarios.first?.name, "Merge - checks green")
    XCTAssertEqual(scenarios.first?.input.action, .mergePr)
    let scenarioId = try XCTUnwrap(scenarios.first).id

    let updated = await store.updateTaskBoardPolicyScenario(
      id: scenarioId,
      name: "Merge - checks red",
      input: PolicyInput(action: .accessSecret)
    )
    XCTAssertTrue(updated)
    scenarios = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.scenarios)
    XCTAssertEqual(scenarios.first?.name, "Merge - checks red")
    XCTAssertEqual(scenarios.first?.input.action, .accessSecret)

    let deleted = await store.deleteTaskBoardPolicyScenario(id: scenarioId)
    XCTAssertTrue(deleted)
    scenarios = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.scenarios)
    XCTAssertTrue(scenarios.isEmpty)
  }
}
