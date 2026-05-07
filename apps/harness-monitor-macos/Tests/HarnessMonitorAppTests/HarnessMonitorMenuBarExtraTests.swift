import HarnessMonitorKit
import XCTest

@testable import HarnessMonitor

final class HarnessMonitorMenuBarExtraTests: XCTestCase {
  func testStatusItemUsesLighthouseAsset() {
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemImageName,
      "HarnessMonitorMenuBarLighthouse"
    )
  }

  func testSnapshotSummarizesStatusAndCounts() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .online,
      sessionCount: 3,
      pendingDecisionCount: 2,
      pendingDecisionSeverity: .warn,
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
      pendingDecisionSeverity: nil,
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
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .starting
    )
    let stopping = HarnessMonitorMenuBarSnapshot(
      connectionState: .idle,
      sessionCount: 1,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
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
        pendingDecisionSeverity: .critical,
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

  func testVisibleDecisionsPublishOrangeAttentionBadgeSummary() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .online,
      sessionCount: 3,
      pendingDecisionCount: 1,
      pendingDecisionSeverity: .needsUser,
      supervisorRuntimeState: .running
    )

    XCTAssertTrue(snapshot.showsAttentionBadge)
    XCTAssertEqual(
      snapshot.statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemWarningImageName
    )
    XCTAssertEqual(snapshot.statusItemDisplayTitle, "Harness Monitor: 1 decision")
    XCTAssertEqual(snapshot.attentionBadgeTintLabel, "orange")
    XCTAssertEqual(
      snapshot.statusItemAccessibilitySummary,
      """
      Connection: Online, Sessions: 3, Decisions: 1, Supervisor: Running, \
      Attention badge: orange
      """
    )
  }

  func testHiddenBadgePublishesHiddenAccessibilitySummary() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .idle,
      sessionCount: 0,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .stopped
    )

    XCTAssertFalse(snapshot.showsAttentionBadge)
    XCTAssertEqual(snapshot.statusItemAssetName, HarnessMonitorMenuBarSnapshot.statusItemImageName)
    XCTAssertEqual(snapshot.statusItemDisplayTitle, "Harness Monitor")
    XCTAssertEqual(snapshot.attentionBadgeAccessibilityLabel, "Attention badge: hidden")
  }

  func testCriticalDecisionUsesCriticalStatusAsset() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .online,
      sessionCount: 3,
      pendingDecisionCount: 2,
      pendingDecisionSeverity: .critical,
      supervisorRuntimeState: .running
    )

    XCTAssertEqual(
      snapshot.statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemCriticalImageName
    )
    XCTAssertEqual(snapshot.statusItemDisplayTitle, "Harness Monitor: 2 decisions")
  }

  func testMenuBarStatusPresentationKeepsIdleAssetStable() {
    let presentation = HarnessMonitorMenuBarStatusPresentation.idle

    XCTAssertEqual(
      presentation.statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemImageName
    )
  }

  func testMenuBarStatusPresentationUsesPreRenderedSeverityAssetsForDynamicStatus() {
    XCTAssertEqual(
      HarnessMonitorMenuBarStatusPresentation(
        pendingDecisionCount: 1,
        pendingDecisionSeverity: .needsUser
      )
      .statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemWarningImageName
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarStatusPresentation(
        pendingDecisionCount: 1,
        pendingDecisionSeverity: .critical
      )
      .statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemCriticalImageName
    )
  }
}
