import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

extension PolicyCanvasStoreTests {
  func testScenarioCreateUpdateDeleteRoundTripsThroughWorkspace() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()

    let created = await store.createPolicyScenario(
      name: "Merge - checks green",
      input: PolicyInput(action: .mergePr)
    )
    XCTAssertTrue(created)
    var scenarios = try XCTUnwrap(
      store.contentUI.dashboard.policyCanvasWorkspace?.scenarios
    )
    XCTAssertEqual(scenarios.count, 1)
    XCTAssertEqual(scenarios.first?.name, "Merge - checks green")
    XCTAssertEqual(scenarios.first?.input.action, .mergePr)
    let scenarioId = try XCTUnwrap(scenarios.first).id

    let updated = await store.updatePolicyScenario(
      id: scenarioId,
      name: "Merge - checks red",
      input: PolicyInput(action: .accessSecret)
    )
    XCTAssertTrue(updated)
    scenarios = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace?.scenarios)
    XCTAssertEqual(scenarios.first?.name, "Merge - checks red")
    XCTAssertEqual(scenarios.first?.input.action, .accessSecret)

    let deleted = await store.deletePolicyScenario(id: scenarioId)
    XCTAssertTrue(deleted)
    scenarios = try XCTUnwrap(store.contentUI.dashboard.policyCanvasWorkspace?.scenarios)
    XCTAssertTrue(scenarios.isEmpty)
  }
}
