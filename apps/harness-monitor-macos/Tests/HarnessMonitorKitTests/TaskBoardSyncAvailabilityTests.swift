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
    XCTAssertEqual(
      availability.warning,
      "Configure a GitHub repository or inbox repository before running sync"
    )
  }

  func testProjectRepositoryEnablesSync() {
    let settings = TaskBoardOrchestratorSettings(
      githubProject: TaskBoardGitHubProjectConfig(owner: "example", repo: "project"),
      policyVersion: "test"
    )

    XCTAssertTrue(TaskBoardGitHubSyncAvailability(settings: settings).canRun)
  }

  func testInboxRepositoryEnablesSync() {
    let settings = TaskBoardOrchestratorSettings(
      githubInbox: TaskBoardGitHubInboxConfig(repositories: [" example/project "]),
      policyVersion: "test"
    )

    XCTAssertTrue(TaskBoardGitHubSyncAvailability(settings: settings).canRun)
  }
}
