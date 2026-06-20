import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels
import XCTest

@testable import HarnessMonitorKit

extension TaskBoardPolicyCanvasStoreTests {
  func testMakeLiveEnforcesActiveCanvasAndEnablesGlobalEnforcement() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    let created = await store.createTaskBoardPolicyCanvas(title: "Release gate")
    XCTAssertTrue(created)

    var document = try XCTUnwrap(store.contentUI.dashboard.taskBoardPolicyPipeline)
    document.revision += 1
    let saved = await store.saveTaskBoardPolicyPipelineDraft(document: document)
    let savedRevision = try XCTUnwrap(saved).revision

    let madeLive = await store.makeLiveTaskBoardPolicyPipeline(revision: savedRevision)
    XCTAssertTrue(madeLive)
    XCTAssertEqual(
      store.contentUI.dashboard.taskBoardPolicyCanvasWorkspace?.globalPolicyEnforcementEnabled,
      true
    )
    XCTAssertEqual(store.contentUI.dashboard.taskBoardPolicyPipeline?.mode, .enforced)
  }

  func testGoLiveDiffReturnsDaemonComparison() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshTaskBoardPolicyPipeline()

    let diff = await store.goLiveDiffTaskBoardPolicyPipeline()
    XCTAssertNotNil(diff)
    XCTAssertEqual(diff?.hasLivePolicy, false)
    XCTAssertEqual(diff?.changedCount, 0)
  }
}
