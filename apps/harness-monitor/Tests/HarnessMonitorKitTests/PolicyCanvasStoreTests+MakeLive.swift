import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

extension PolicyCanvasStoreTests {
  func testMakeLiveEnforcesActiveCanvasAndEnablesGlobalEnforcement() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()

    let created = await store.createPolicyCanvas(title: "Release gate")
    XCTAssertTrue(created)

    var document = try XCTUnwrap(store.contentUI.dashboard.policyPipeline)
    document.revision += 1
    let saved = await store.savePolicyPipelineDraft(document: document)
    let savedRevision = try XCTUnwrap(saved).revision

    let madeLive = await store.makeLivePolicyPipeline(revision: savedRevision)
    XCTAssertTrue(madeLive)
    XCTAssertEqual(
      store.contentUI.dashboard.policyCanvasWorkspace?.globalPolicyEnforcementEnabled,
      true
    )
    XCTAssertEqual(store.contentUI.dashboard.policyPipeline?.mode, .enforced)
  }

  func testGoLiveDiffReturnsDaemonComparison() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()

    let diff = await store.goLiveDiffPolicyPipeline()
    XCTAssertNotNil(diff)
    XCTAssertEqual(diff?.hasLivePolicy, false)
    XCTAssertEqual(diff?.changedCount, 0)
  }
}
