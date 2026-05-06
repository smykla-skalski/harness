import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit

final class HarnessMonitorMenuBarExtraTests: XCTestCase {
  func testSnapshotSummarizesStatusAndCounts() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .online,
      sessionCount: 3,
      pendingDecisionCount: 2,
      supervisorRuntimeState: .running
    )

    XCTAssertEqual(snapshot.connectionLabel, "Connection: Online")
    XCTAssertEqual(snapshot.sessionCountLabel, "Sessions: 3")
    XCTAssertEqual(snapshot.pendingDecisionLabel, "Decisions: 2")
    XCTAssertEqual(snapshot.supervisorLabel, "Supervisor: Running")
    XCTAssertEqual(snapshot.supervisorToggleLabel, "Disable Supervisor")
    XCTAssertFalse(snapshot.supervisorToggleDisabled)
  }

  func testStoppedSnapshotOffersEnableSupervisor() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .offline("bridge unavailable"),
      sessionCount: 0,
      pendingDecisionCount: 0,
      supervisorRuntimeState: .stopped
    )

    XCTAssertEqual(snapshot.connectionLabel, "Connection: Offline")
    XCTAssertEqual(snapshot.supervisorLabel, "Supervisor: Stopped")
    XCTAssertEqual(snapshot.supervisorToggleLabel, "Enable Supervisor")
    XCTAssertFalse(snapshot.supervisorToggleDisabled)
  }

  func testTransitionalSupervisorStatesDisableToggle() {
    let starting = HarnessMonitorMenuBarSnapshot(
      connectionState: .connecting,
      sessionCount: 1,
      pendingDecisionCount: 0,
      supervisorRuntimeState: .starting
    )
    let stopping = HarnessMonitorMenuBarSnapshot(
      connectionState: .idle,
      sessionCount: 1,
      pendingDecisionCount: 0,
      supervisorRuntimeState: .stopping
    )

    XCTAssertEqual(starting.supervisorLabel, "Supervisor: Starting")
    XCTAssertEqual(starting.supervisorToggleLabel, "Disable Supervisor")
    XCTAssertTrue(starting.supervisorToggleDisabled)
    XCTAssertEqual(stopping.supervisorLabel, "Supervisor: Stopping")
    XCTAssertEqual(stopping.supervisorToggleLabel, "Enable Supervisor")
    XCTAssertTrue(stopping.supervisorToggleDisabled)
  }

  func testVisibleMenuLabelsStayWithinThirtyCharacters() {
    let states: [HarnessMonitorStore.SupervisorRuntimeState] = [
      .stopped,
      .starting,
      .running,
      .stopping,
    ]

    let labels = states.flatMap { state in
      HarnessMonitorMenuBarSnapshot(
        connectionState: .offline("ignored reason"),
        sessionCount: 42_000,
        pendingDecisionCount: 42_000,
        supervisorRuntimeState: state
      ).visibleMenuLabels
    }

    for label in labels {
      XCTAssertLessThanOrEqual(
        label.count,
        30,
        "\(label) must stay short enough for the menu bar extra"
      )
    }
  }
}
