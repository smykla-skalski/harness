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
      pendingDecisionCount: 2,
      pendingDecisionSeverity: .warn,
      supervisorRuntimeState: .running
    )

    XCTAssertEqual(snapshot.connectionLabel, "Connection: Online")
    XCTAssertEqual(snapshot.monitoringLabel, "Monitoring: Active work")
    XCTAssertEqual(snapshot.activeWorkCountLabel, "Active work: 1")
    XCTAssertEqual(snapshot.pendingDecisionLabel, "Decisions: 2")
    XCTAssertEqual(snapshot.supervisorLabel, "Supervisor: Running")
    XCTAssertEqual(snapshot.supervisorToggleLabel, "Disable Supervisor")
    XCTAssertFalse(snapshot.supervisorToggleDisabled)
  }

  func testStoppedSnapshotOffersEnableSupervisor() {
    let snapshot = makeSnapshot(
      connectionState: .offline("bridge unavailable"),
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
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .starting
    )
    let stopping = makeSnapshot(
      connectionState: .idle,
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
      Connection: Online, Monitoring: Active work, Active work: 1, Decisions: 1, \
      Attention badge: orange
      """
    )
  }

  func testHiddenBadgePublishesHiddenAccessibilitySummary() {
    let snapshot = makeSnapshot(
      connectionState: .idle,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .stopped
    )

    XCTAssertFalse(snapshot.showsAttentionBadge)
    XCTAssertEqual(snapshot.statusItemAssetName, HarnessMonitorMenuBarSnapshot.statusItemImageName)
    XCTAssertEqual(snapshot.statusItemDisplayTitle, "Harness Monitor")
    XCTAssertEqual(snapshot.attentionBadgeAccessibilityLabel, "Attention badge: hidden")
  }

  func testIdleMonitoringPublishesWorkBasedTooltipAndAccessibilityState() {
    let snapshot = makeSnapshot(
      connectionState: .idle,
      pendingDecisionCount: 0,
      pendingDecisionSeverity: nil,
      supervisorRuntimeState: .stopped,
      activeWorkCount: 0
    )

    XCTAssertTrue(snapshot.isMonitoringIdle)
    XCTAssertEqual(snapshot.monitoringLabel, "Monitoring: No active work")
    XCTAssertEqual(
      snapshot.statusItemHelpText,
      "No active work"
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemHelpText(hasActiveWork: false),
      snapshot.statusItemHelpText
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemAccessibilityLabel(
        hasActiveWork: false,
        pendingDecisionCount: 0
      ),
      "Harness Monitor: No active work"
    )
    XCTAssertEqual(
      snapshot.statusItemAccessibilitySummary,
      """
      Connection: Idle, Monitoring: No active work, Active work: 0, Decisions: 0, \
      Attention badge: hidden
      """
    )
  }

  func testCriticalDecisionUsesCriticalStatusAsset() {
    let snapshot = makeSnapshot(
      connectionState: .online,
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

  func testAttentionRemainsVisibleWithoutActiveWork() {
    let snapshot = makeSnapshot(
      connectionState: .online,
      pendingDecisionCount: 1,
      pendingDecisionSeverity: .critical,
      supervisorRuntimeState: .running,
      activeWorkCount: 0
    )

    XCTAssertTrue(snapshot.isMonitoringIdle)
    XCTAssertTrue(snapshot.showsAttentionBadge)
    XCTAssertEqual(
      snapshot.statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemCriticalImageName
    )
    XCTAssertEqual(
      HarnessMonitorMenuBarSnapshot.statusItemAccessibilityLabel(
        hasActiveWork: false,
        pendingDecisionCount: 1
      ),
      "Harness Monitor: No active work: 1 decision"
    )
  }

  func testMenuBarStatusPresentationUsesActiveWorkForIdleAsset() {
    let presentation = HarnessMonitorMenuBarStatusPresentation.idle

    XCTAssertEqual(
      presentation.statusItemAssetName,
      HarnessMonitorMenuBarSnapshot.statusItemImageName
    )
    XCTAssertEqual(
      presentation.statusItemAssetName(
        hasActiveWork: false,
        showsStateColorVariants: true
      ),
      HarnessMonitorMenuBarSnapshot.statusItemIdleImageName
    )
    XCTAssertEqual(
      presentation.statusItemAssetName(
        hasActiveWork: true,
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
    pendingDecisionCount: Int,
    pendingDecisionSeverity: DecisionSeverity?,
    supervisorRuntimeState: HarnessMonitorStore.SupervisorRuntimeState,
    activeWorkCount: Int = 1,
    runsWhenClosed: Bool = false
  ) -> HarnessMonitorMenuBarSnapshot {
    HarnessMonitorMenuBarSnapshot(
      connectionState: connectionState,
      pendingDecisionCount: pendingDecisionCount,
      pendingDecisionSeverity: pendingDecisionSeverity,
      supervisorRuntimeState: supervisorRuntimeState,
      activeWorkCount: activeWorkCount,
      runsWhenClosed: runsWhenClosed
    )
  }
}
