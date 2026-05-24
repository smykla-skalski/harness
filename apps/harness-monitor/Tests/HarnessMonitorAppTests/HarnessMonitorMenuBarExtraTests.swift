import HarnessMonitorKit
import XCTest

@testable import HarnessMonitor

final class HarnessMonitorMenuBarExtraTests: XCTestCase {
  func testStatusItemUsesLighthouseAsset() {
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemImageName,
      "HarnessMonitorMenuBarLighthouse"
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemIdleImageName,
      "HarnessMonitorMenuBarLighthouseInfo"
    )
  }

  func testSnapshotSummarizesStatusAndCounts() {
    let snapshot = makeSnapshot(
      connectionState: .online,
      sessionCount: 3,
      pendingDecisionCount: 2,
      pendingDecisionSeverity: .warn,
      supervisorRuntimeState: .running
    )

    XCTAssertEqual(snapshot.connectionLabel, "Connection: Online")
    XCTAssertEqual(snapshot.monitoringLabel, "Monitoring: Active session")
    XCTAssertEqual(snapshot.sessionCountLabel, "Sessions: 3")
    XCTAssertEqual(snapshot.pendingDecisionLabel, "Decisions: 2")
    XCTAssertEqual(snapshot.supervisorLabel, "Supervisor: Running")
    XCTAssertEqual(snapshot.supervisorToggleLabel, "Disable Supervisor")
    XCTAssertFalse(snapshot.supervisorToggleDisabled)
  }

  func testStoppedSnapshotOffersEnableSupervisor() {
    let snapshot = makeSnapshot(
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
    let starting = makeSnapshot(
      connectionState: .connecting,
      sessionCount: 1,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .starting
    )
    let stopping = makeSnapshot(
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
      makeSnapshot(
        connectionState: .offline("ignored reason"),
        sessionCount: 42_000,
        pendingDecisionCount: 42_000,
        pendingDecisionSeverity: .critical,
        supervisorRuntimeState: state
      )
      .visibleMenuLabels
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
    let snapshot = makeSnapshot(
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
      Connection: Online, Monitoring: Active session, Sessions: 3, Decisions: 1, \
      Attention badge: orange
      """
    )
  }

  func testHiddenBadgePublishesHiddenAccessibilitySummary() {
    let snapshot = makeSnapshot(
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

  func testIdleMonitoringPublishesTooltipAndAccessibilityState() {
    let snapshot = makeSnapshot(
      connectionState: .idle,
      sessionCount: 0,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .stopped,
      activeSessionWindowCount: 0
    )

    XCTAssertTrue(snapshot.isMonitoringIdle)
    XCTAssertEqual(snapshot.monitoringLabel, "Monitoring: No active session")
    XCTAssertEqual(
      snapshot.statusItemHelpText,
      "No active session - open one to monitor"
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemHelpText(activeSessionWindowCount: 0),
      snapshot.statusItemHelpText
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemAccessibilityLabel(activeSessionWindowCount: 0),
      "Harness Monitor: No active session - open one to monitor"
    )
    XCTAssertEqual(
      snapshot.statusItemAccessibilitySummary,
      """
      Connection: Idle, Monitoring: No active session, Sessions: 0, Decisions: 0, \
      No active session - open one to monitor, Attention badge: hidden
      """
    )
  }

  func testCriticalDecisionUsesCriticalStatusAsset() {
    let snapshot = makeSnapshot(
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
    XCTAssertEqual(
      presentation.statusItemAssetName(
        activeSessionWindowCount: 0,
        showsStateColorVariants: true
      ),
      HarnessMonitorMenuBarSnapshot.statusItemIdleImageName
    )
    XCTAssertEqual(
      presentation.statusItemAssetName(
        activeSessionWindowCount: 1,
        showsStateColorVariants: true
      ),
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

  func testMenuBarStatusPresentationCanSuppressStateColoredVariants() {
    let presentation = HarnessMonitorMenuBarStatusPresentation(
      pendingDecisionCount: 1,
      pendingDecisionSeverity: .critical
    )

    XCTAssertEqual(
      presentation.statusItemAssetName(showsStateColorVariants: false),
      HarnessMonitorMenuBarSnapshot.statusItemImageName
    )
    XCTAssertEqual(
      presentation.statusItemAssetName(showsStateColorVariants: true),
      HarnessMonitorMenuBarSnapshot.statusItemCriticalImageName
    )
  }

  private func makeSnapshot(
    connectionState: HarnessMonitorStore.ConnectionState,
    sessionCount: Int,
    pendingDecisionCount: Int,
    pendingDecisionSeverity: DecisionSeverity?,
    supervisorRuntimeState: HarnessMonitorStore.SupervisorRuntimeState,
    activeSessionWindowCount: Int = 1,
    runsWhenClosed: Bool = false
  ) -> HarnessMonitorMenuBarSnapshot {
    HarnessMonitorMenuBarSnapshot(
      connectionState: connectionState,
      sessionCount: sessionCount,
      pendingDecisionCount: pendingDecisionCount,
      pendingDecisionSeverity: pendingDecisionSeverity,
      supervisorRuntimeState: supervisorRuntimeState,
      activeSessionWindowCount: activeSessionWindowCount,
      runsWhenClosed: runsWhenClosed
    )
  }
}
