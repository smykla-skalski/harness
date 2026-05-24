import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Harness Monitor UI-test accessibility registry extended mirror")
struct HarnessMonitorUITestAccessibilityRegistryMoreTests {
  @Test("MCP reliability identifiers match UI-test mirror")
  func mcpReliabilityIdentifiersMirror() throws {
    #expect(HarnessMonitorAccessibility.settingsMCPSection == "harness.settings.mcp")
    #expect(
      HarnessMonitorAccessibility.settingsMCPRegistryHostToggle
        == "harness.settings.mcp.registry-host"
    )
    #expect(HarnessMonitorAccessibility.settingsMCPStatus == "harness.settings.mcp.status")
    #expect(HarnessMonitorAccessibility.mcpBanner == "harness.content.mcp.banner")

    let sessionToolbar = try sourceFile(named: "SessionWindowToolbar.swift")
    let windowChromeBanners = try sourceFile(named: "WindowChromeBanners.swift")
    let settingsMCP = try sourceFile(named: "SettingsMCPSection.swift")

    #expect(!sessionToolbar.contains("mcpToolbarStatus"))
    #expect(windowChromeBanners.contains("MCPStatusBanner(status: contentChrome.mcpStatus)"))
    #expect(settingsMCP.contains("settingsMCPStatus"))
  }

  @Test("Menu bar extra identifiers match UI-test mirror")
  func menuBarExtraIdentifiersMirror() {
    #expect(HarnessMonitorAccessibility.menuBarExtra == "harness.menu-bar.extra")
    #expect(
      HarnessMonitorAccessibility.menuBarConnectionStatus
        == "harness.menu-bar.status.connection"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSessionStatus
        == "harness.menu-bar.status.sessions"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarDecisionStatus == "harness.menu-bar.status.decisions"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorStatus
        == "harness.menu-bar.status.supervisor"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenMonitor
        == "harness.menu-bar.action.open-monitor"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenSession
        == "harness.menu-bar.action.open-session"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarOpenSettings
        == "harness.menu-bar.action.open-settings"
    )
    #expect(HarnessMonitorAccessibility.menuBarRefresh == "harness.menu-bar.action.refresh")
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorToggle
        == "harness.menu-bar.action.supervisor-toggle"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarSupervisorCheckNow
        == "harness.menu-bar.action.supervisor-check-now"
    )
    #expect(
      HarnessMonitorAccessibility.menuBarRunWhenClosed
        == "harness.menu-bar.action.run-when-closed"
    )
    #expect(HarnessMonitorAccessibility.menuBarQuit == "harness.menu-bar.action.quit")
  }

  @Test("Settings appearance identifiers match UI-test mirror")
  func settingsAppearanceIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.settingsMenuBarStateColorsToggle
        == "harness.settings.menu-bar.state-colors"
    )
    #expect(
      HarnessMonitorAccessibility.settingsSessionShortcutOverlaysToggle
        == "harness.settings.session.shortcut-overlays"
    )
    #expect(
      HarnessMonitorAccessibility.settingsSessionTitleBlurToggle
        == "harness.settings.session.title-blur"
    )
  }

  @Test("Settings repositories, reviews, and secrets identifiers match UI-test mirror")
  func settingsRepositoriesReviewsAndSecretsIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.settingsRepositoriesSection
        == "harness.settings.section.repositories"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsSection
        == "harness.settings.section.reviews"
    )
    #expect(
      HarnessMonitorAccessibility.settingsSecretsSection
        == "harness.settings.section.secrets"
    )
    #expect(HarnessMonitorAccessibility.settingsRepositoriesRoot == "harness.settings.repositories")
    #expect(HarnessMonitorAccessibility.settingsReviewsRoot == "harness.settings.reviews")
    #expect(HarnessMonitorAccessibility.settingsSecretsRoot == "harness.settings.secrets")
    #expect(
      HarnessMonitorAccessibility.settingsRepositoriesSaveButton
        == "harness.settings.repositories.save"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsSaveButton
        == "harness.settings.reviews.save"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsShowRowAvatarsToggle
        == "harness.settings.reviews.show-row-avatars"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsShowRowLabelsToggle
        == "harness.settings.reviews.show-row-labels"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsShowRowLineCountersToggle
        == "harness.settings.reviews.show-row-line-counters"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsWrapRowTitlesToggle
        == "harness.settings.reviews.wrap-row-titles"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsRowTitleMaximumLinesField
        == "harness.settings.reviews.row-title-maximum-lines"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsHideSemanticPrefixesInRowTitlesToggle
        == "harness.settings.reviews.hide-semantic-prefixes"
    )
    #expect(
      HarnessMonitorAccessibility.settingsSecretsSaveButton
        == "harness.settings.secrets.save"
    )
  }

  @Test("New session capability identifiers match UI-test mirror")
  func newSessionCapabilityIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityRow("Copilot CLI")
        == "harness.new-session.capability.copilot-cli"
    )
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityProbe("Copilot CLI")
        == "harness.new-session.capability.copilot-cli.probe"
    )
    #expect(
      HarnessMonitorAccessibility.newSessionCapabilityTransportButton(
        "Copilot CLI",
        transportID: "managed:copilot"
      )
        == "harness.new-session.capability.copilot-cli.transport.managed-copilot"
    )
  }

  @Test("Dashboard route sidebar stays accessibility-addressable")
  func dashboardRouteSidebarStaysAccessibilityAddressable() throws {
    let dashboardView = try sourceFile(named: "DashboardWindowSupport.swift")
    let dashboardSidebarSessionsView = try sourceFile(
      named: "DashboardSidebarRecentSessionsSection.swift"
    )
    let sharedSidebarView = try sourceFile(named: "HarnessMonitorSidebar.swift")

    #expect(dashboardView.contains("HarnessMonitorAccessibility.dashboardSidebar"))
    #expect(
      dashboardView.contains("HarnessMonitorAccessibility.dashboardWindowRoute(route.rawValue)"))
    #expect(
      dashboardSidebarSessionsView.contains(
        "HarnessMonitorAccessibility.sessionRow(session.sessionId)"
      )
    )
    #expect(dashboardView.contains("HarnessMonitorSidebar("))
    #expect(dashboardView.contains("List(selection: dashboardSelectionBinding)"))
    #expect(dashboardView.contains("SessionSidebarRow("))
    #expect(!dashboardView.contains("Section(\"Routes\")"))
    #expect(dashboardView.contains("DashboardSidebarRecentSessionsSection("))
    #expect(dashboardSidebarSessionsView.contains("Section(\"Sessions\")"))
    #expect(dashboardSidebarSessionsView.contains("subtitle: subtitle"))
    #expect(dashboardView.contains(".harnessMonitorSidebarListChrome("))
    #expect(
      dashboardView.contains(".accessibilityValue(isSelected ? \"selected\" : \"not selected\")"))
    #expect(sharedSidebarView.contains("HarnessMonitorSidebarListChromeModifier"))
    #expect(sharedSidebarView.contains("SessionSidebarFooter(model: statusModel)"))
    #expect(sharedSidebarView.contains(".accessibilityIdentifier(accessibilityIdentifier)"))
    #expect(sharedSidebarView.contains(".accessibilityValue(accessibilityValue)"))
  }

  @Test("Agents runtime identifiers match UI-test mirror")
  func agentsRuntimeIdentifiersMirror() {
    #expect(
      HarnessMonitorAccessibility.agentRuntimeStrip("worker-codex")
        == "harness.agent.detail.runtime.strip.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdog("worker-codex")
        == "harness.agent.detail.runtime.watchdog.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimePendingPermissions("worker-codex")
        == "harness.agent.detail.runtime.pending-permissions.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDeadline("worker-codex")
        == "harness.agent.detail.runtime.deadline.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosure("worker-codex")
        == "harness.agent.detail.runtime.disclosure.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeDisclosureContent("worker-codex")
        == "harness.agent.detail.runtime.disclosure-content.worker-codex"
    )
    #expect(
      HarnessMonitorAccessibility.agentRuntimeWatchdogAccessibilityState
        == "harness.agent.detail.runtime.watchdog.accessibility.state"
    )
    #expect(
      HarnessMonitorAccessibility.toolCallTimelineAccessibilityState
        == "harness.timeline.tool-call.accessibility.state"
    )
  }

  @Test("Slug normalises delimiters and casing")
  func slugNormalisation() {
    #expect(
      HarnessMonitorAccessibility.arbitrationBanner("Task_Foo:Bar.1")
        == "harness.banner.arbitration.task-foo-bar1"
    )
    #expect(
      HarnessMonitorAccessibility.heuristicIssueCard("runtime.already_reviewing")
        == "heuristicIssueCard.runtime.already_reviewing"
    )
  }

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

  @Test("Passive task-drop borders stay static while targeted feedback owns animation")
  func passiveTaskDropBordersStayStaticWhileTargetedFeedbackOwnsAnimation() throws {
    let laneSupport = try sourceFile(named: "SessionAgentLaneSupport.swift")

    #expect(laneSupport.contains("struct DropTargetPulseBorder: View"))
    #expect(laneSupport.contains(".opacity(reduceMotion ? 0.6 : 0.35)"))
    #expect(!laneSupport.contains("phaseAnimator"))
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceRoots = [
      repoRoot.appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views"
      ),
      repoRoot.appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitor/App"
      ),
      repoRoot.appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable"
      ),
    ]

    for sourceRoot in sourceRoots {
      let fileURL = sourceRoot.appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: fileURL.path) {
        return try String(contentsOf: fileURL, encoding: .utf8)
      }
    }

    let requestedBasename = URL(fileURLWithPath: relativePath).lastPathComponent
    let candidateURLs =
      Array(
        Set(
          sourceRoots.flatMap { sourceRoot in
            FileManager.default.enumerator(
              at: sourceRoot,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles]
            )?
            .compactMap { element -> URL? in
              guard let url = element as? URL, url.lastPathComponent == requestedBasename else {
                return nil
              }
              return url
            } ?? []
          }
        )
      )

    if let matchedURL = candidateURLs.first(where: { $0.path.hasSuffix("/\(relativePath)") }) {
      return try String(contentsOf: matchedURL, encoding: .utf8)
    }
    guard candidateURLs.count == 1, let resolvedURL = candidateURLs.first else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: resolvedURL, encoding: .utf8)
  }
}
