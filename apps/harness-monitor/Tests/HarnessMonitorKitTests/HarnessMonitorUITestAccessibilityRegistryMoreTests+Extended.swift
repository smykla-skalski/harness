import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryMoreTests {
  @Test("Review accessibility identifiers are attached by production views")
  func reviewAccessibilityIdentifiersAreAttachedByProductionViews() throws {
    let cockpitView = try sourceFile(named: "SessionCockpitView.swift")
    let taskLaneView = try sourceFile(named: "SessionTaskLaneViews.swift")
    let agentLaneView = try sourceFile(named: "SessionAgentLaneViews.swift")
    let taskActionsSheet = try sourceFile(named: "Actions/TaskActionsSheet.swift")
    let toastView = try sourceFile(named: "HarnessMonitorFeedbackToastView.swift")

    #expect(cockpitView.contains("SessionCockpitHeuristicIssuesSection"))
    #expect(cockpitView.contains("sessionCockpitScrollView"))
    #expect(taskLaneView.contains("sessionTaskListState"))
    #expect(taskActionsSheet.contains("ReviewStatePanel(task: task)"))
    #expect(taskLaneView.contains("harnessTrackMCPElement"))
    #expect(agentLaneView.contains("accessibilityTestProbe"))
    #expect(toastView.contains("feedback.accessibilityIdentifier"))
  }

  @Test("Task actions sheet keeps using presented session detail during refresh")
  func taskActionsSheetUsesPresentedSessionDetailDuringRefresh() throws {
    let taskActionsSheet = try sourceFile(named: "Actions/TaskActionsSheet.swift")

    #expect(taskActionsSheet.contains("contentUI.sessionDetail.presentedSessionDetail"))
  }

  @Test("Shared toolbar and probe views publish MCP tracking")
  func sharedToolbarAndProbeViewsPublishMCPTracking() throws {
    let accessibilitySupport = try sourceFile(named: "HarnessMonitorAccessibilitySupport.swift")
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")
    let reviewsProvenance = try sourceFile(named: "DashboardReviewsProvenance.swift")
    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")
    let sleepToolbarButton = try sourceFile(named: "SleepPreventionToolbarButton.swift")
    let sessionAttentionToolbarButton = try sourceFile(named: "SessionAttentionToolbarButton.swift")

    #expect(accessibilitySupport.contains(".harnessMCPText("))
    #expect(dashboardToolbar.contains(".harnessMCPButton("))
    #expect(reviewsProvenance.contains(".harnessMCPButton("))
    #expect(sessionToolbar.contains(".harnessMCPButton("))
    #expect(sleepToolbarButton.contains(".harnessMCPButton("))
    #expect(sessionAttentionToolbarButton.contains(".harnessMCPButton("))
  }

  @Test("Dashboard toolbar splits trailing actions into separate glass capsules")
  func dashboardToolbarSplitsTrailingActionsIntoSeparateGlassCapsules() throws {
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")
    let dashboardWindow = try sourceFile(named: "DashboardWindowView.swift")

    #expect(dashboardWindow.contains(".toolbar {"))
    #expect(dashboardToolbar.contains("struct DashboardWindowToolbar: ToolbarContent"))
    #expect(dashboardToolbar.contains("ToolbarItem(placement: .primaryAction)"))
    #expect(dashboardToolbar.contains("ToolbarSpacer(.fixed, placement: .primaryAction)"))
    #expect(!dashboardToolbar.contains("ToolbarItemGroup(placement: .secondaryAction)"))
    #expect(!dashboardToolbar.contains(".sharedBackgroundVisibility(.hidden)"))
    #expect(!dashboardToolbar.contains("Divider()"))
  }

  @Test("Policy kill switch keeps native toolbar glass and spacing")
  func policyKillSwitchKeepsNativeToolbarGlassAndSpacing() throws {
    let killSwitchToolbar = try sourceFile(
      named: "Toolbar/PolicyEnforcementKillSwitchToolbarGroup.swift"
    )
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")
    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")
    let settingsView = try sourceFile(named: "SettingsView.swift")
    let policyCanvasLab = try sourceFile(named: "PolicyCanvasLabWindowView.swift")

    #expect(killSwitchToolbar.contains("ToolbarItemGroup(placement: .primaryAction)"))
    #expect(!killSwitchToolbar.contains(".buttonStyle(.glass)"))
    #expect(!killSwitchToolbar.contains(".sharedBackgroundVisibility(.hidden)"))
    #expect(
      dashboardToolbar.contains(
        """
        PolicyEnforcementKillSwitchToolbarGroup(store: store)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        """
      )
    )
    #expect(
      sessionToolbar.contains(
        """
        PolicyEnforcementKillSwitchToolbarGroup(store: store)
              ToolbarSpacer(.fixed, placement: .primaryAction)
        """
      )
    )
    #expect(
      settingsView.contains(
        """
        PolicyEnforcementKillSwitchToolbarGroup(store: store)

            if selectedSection == .supervisor {
              ToolbarSpacer(.fixed, placement: .primaryAction)
        """
      )
    )
    #expect(
      policyCanvasLab.contains(
        """
        PolicyEnforcementKillSwitchToolbarGroup(store: store)
                ToolbarSpacer(.fixed, placement: .primaryAction)
        """
      )
    )
  }

  @Test("Passive task-drop borders stay static while targeted feedback owns animation")
  func passiveTaskDropBordersStayStaticWhileTargetedFeedbackOwnsAnimation() throws {
    let laneSupport = try sourceFile(named: "SessionAgentLaneSupport.swift")

    #expect(laneSupport.contains("struct DropTargetPulseBorder: View"))
    #expect(laneSupport.contains(".opacity(reduceMotion ? 0.6 : 0.35)"))
    #expect(!laneSupport.contains("phaseAnimator"))
  }
}
