import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorUIPreviewable

final class TaskBoardSyncAvailabilityTests: XCTestCase {
  func testUnknownSettingsDoNotDisableSync() {
    let availability = TaskBoardGitHubSyncAvailability(settings: nil)

    XCTAssertTrue(availability.canRun)
    XCTAssertNil(availability.warning)
  }

  func testDefaultSettingsDisableSyncUntilGitHubRepositoryExists() {
    let availability = TaskBoardGitHubSyncAvailability(
      settings: TaskBoardOrchestratorSettings(policyVersion: "test")
    )

    XCTAssertFalse(availability.canRun)
    XCTAssertEqual(availability.warning, "Add a monitored repository before running sync")
  }

  // The test that a configured project owner/repo alone did not enable sync is
  // gone with the fields: settings no longer carry a publication repository, so
  // the state it guarded cannot be built. The monitored list is now the only
  // input, which the two tests around this cover.

  func testInboxRepositoryEnablesSync() {
    let settings = TaskBoardOrchestratorSettings(
      githubInbox: TaskBoardGitHubInboxConfig(repositories: [" example/project "]),
      policyVersion: "test"
    )

    XCTAssertTrue(TaskBoardGitHubSyncAvailability(settings: settings).canRun)
  }
}
