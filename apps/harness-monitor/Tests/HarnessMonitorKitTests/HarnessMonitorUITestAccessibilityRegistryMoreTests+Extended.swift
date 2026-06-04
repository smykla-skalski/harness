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
    let sessionWindow = try sourceFile(named: "SessionWindowView.swift")
    let sessionColumns = try sourceFile(named: "SessionWindowView+Columns.swift")
    let sessionUnavailable = try sourceFile(named: "SessionWindowView+Unavailable.swift")
    let settingsView = try sourceFile(named: "SettingsView.swift")

    #expect(dashboardWindow.contains(".geometryGroup()\n        .toolbar {"))
    #expect(
      !dashboardWindow.contains(
        "accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoot)\n      .toolbar {"
      )
    )
    #expect(!sessionWindow.contains(".toolbar { sessionToolbar }"))
    #expect(
      sessionColumns.contains(
        ".modifier(\n      SessionWindowPlainTapRecorder(\n        stateCache: stateCache"
      )
    )
    #expect(
      sessionColumns.contains(
        "    )\n    .toolbar { sessionToolbar }\n  }\n\n  @ViewBuilder var standardSessionLayout"
      )
    )
    #expect(
      sessionColumns.contains(
        """
        sessionBannerStack {
                standardSessionDetailSurface
              }
              .toolbar { sessionToolbar }
        """
      )
    )
    #expect(sessionUnavailable.contains(".toolbar { sessionToolbar }"))
    #expect(settingsView.contains("SettingsDetailSwitch(\n        store: store"))
    #expect(
      settingsView.contains(
        "selectedReviewsPane: $selectedReviewsPane\n      )\n      .toolbar {"
      )
    )
    #expect(dashboardToolbar.contains("struct DashboardWindowToolbar: ToolbarContent"))
    #expect(dashboardToolbar.contains("ToolbarItem(placement: .primaryAction)"))
    #expect(dashboardToolbar.contains("ToolbarSpacer(.fixed, placement: .primaryAction)"))
    #expect(!dashboardToolbar.contains("ToolbarItemGroup(placement: .secondaryAction)"))
    #expect(dashboardToolbar.contains(".sharedBackgroundVisibility(.hidden)"))
    #expect(!dashboardToolbar.contains("Divider()"))
  }

  @Test("Policy kill switch keeps native toolbar glass and stays out of the lab")
  func policyKillSwitchKeepsNativeToolbarGlassAndStaysOutOfLab() throws {
    let killSwitchToolbar = try sourceFile(
      named: "Toolbar/PolicyEnforcementKillSwitchToolbarGroup.swift"
    )
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")
    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")
    let settingsView = try sourceFile(named: "SettingsView.swift")
    let policyCanvasLabSources = try sourceFiles(pathContaining: "PolicyCanvasLab")

    #expect(killSwitchToolbar.contains("ToolbarItemGroup(placement: .primaryAction)"))
    #expect(!killSwitchToolbar.contains(".buttonStyle(.glass)"))
    #expect(!killSwitchToolbar.contains(".sharedBackgroundVisibility(.hidden)"))
    #expect(
      dashboardToolbar.contains(
        """
        SleepPreventionToolbarButton(
                store: store,
                presentation: sleepPreventionPresentation
              )
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
              .sharedBackgroundVisibility(.hidden)

            PolicyEnforcementKillSwitchToolbarGroup(store: store)
        """
      )
    )
    #expect(
      sessionToolbar.contains(
        """
        SleepPreventionToolbarButton(
                  store: store,
                  presentation: model.sleepPreventionPresentation
                )
              }
              ToolbarSpacer(.fixed, placement: .primaryAction)
                .sharedBackgroundVisibility(.hidden)

              PolicyEnforcementKillSwitchToolbarGroup(store: store)
        """
      )
    )
    #expect(
      settingsView.contains(
        """
        PolicyEnforcementKillSwitchToolbarGroup(store: store)

            if selectedSection == .supervisor {
              ToolbarSpacer(.fixed, placement: .primaryAction)
                .sharedBackgroundVisibility(.hidden)
        """
      )
    )
    #expect(
      settingsView.contains(
        """
            } else if selectedSection == .reviews {
              ToolbarSpacer(.fixed, placement: .primaryAction)
                .sharedBackgroundVisibility(.hidden)
        """
      )
    )
    #expect(
      policyCanvasLabSources.allSatisfy {
        !$0.contains("PolicyEnforcementKillSwitchToolbarGroup(store: store)")
      }
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
