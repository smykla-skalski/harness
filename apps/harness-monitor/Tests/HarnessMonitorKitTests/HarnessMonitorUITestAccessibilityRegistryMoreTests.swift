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
      HarnessMonitorAccessibility.settingsReviewsPane("pane-picker")
        == "harness.settings.reviews.pane-picker"
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
      HarnessMonitorAccessibility.settingsReviewsGeneratedPatternsTable
        == "harness.settings.reviews.generated-patterns"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsGeneratedPatternField
        == "harness.settings.reviews.generated-patterns.field"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsGeneratedPatternAddButton
        == "harness.settings.reviews.generated-patterns.add"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsRestoreDefaultsButton
        == "harness.settings.reviews.generated-patterns.restore-defaults"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsPullRequestNumberToggle
        == "harness.settings.reviews.show-row-pr-number"
    )
    #expect(
      HarnessMonitorAccessibility.settingsReviewsPullRequestAgeToggle
        == "harness.settings.reviews.show-row-pr-age"
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
      HarnessMonitorAccessibility.settingsReviewsSemanticPrefixesToggle
        == "harness.settings.reviews.hide-semantic-prefixes"
    )
    #expect(
      HarnessMonitorAccessibility.settingsSecretsSaveButton
        == "harness.settings.secrets.save"
    )
  }

  @Test("Settings reviews generated-pattern identifiers are attached by production views")
  func settingsReviewsGeneratedPatternIdentifiersAreAttachedByProductionViews() throws {
    let reviewsFiles = try sourceFile(named: "SettingsReviewsFilesSection.swift")
    let filesPane = try sourceFile(named: "SettingsReviewsFilesPane.swift")

    #expect(
      reviewsFiles.contains("HarnessMonitorAccessibility.settingsReviewsGeneratedPatternsTable")
    )
    #expect(
      reviewsFiles.contains("HarnessMonitorAccessibility.settingsReviewsGeneratedPatternField")
    )
    #expect(
      reviewsFiles.contains("HarnessMonitorAccessibility.settingsReviewsGeneratedPatternAddButton")
    )
    #expect(
      reviewsFiles.contains(
        "HarnessMonitorAccessibility.settingsReviewsRestoreDefaultsButton")
    )
    #expect(
      reviewsFiles.contains("HarnessMonitorAccessibility.settingsReviewsGeneratedPatternRow(index)")
    )
    #expect(
      reviewsFiles.contains(
        "HarnessMonitorAccessibility.settingsReviewsGeneratedPatternRemoveButton(index)")
    )
    #expect(reviewsFiles.contains("Label(\"Add Pattern\", systemImage: \"plus\")"))
    #expect(reviewsFiles.contains("\"Generated file patterns\""))
    #expect(!reviewsFiles.contains("DisclosureGroup(\"Files\")"))
    #expect(filesPane.contains("Text(\"Files\").harnessNativeFormSectionHeader()"))
    #expect(filesPane.contains(".accessibilityIdentifier(\"settingsReviewFilesSection\")"))
  }

  @Test("Settings reviews pane identifiers are attached by production views")
  func settingsReviewsPaneIdentifiersAreAttachedByProductionViews() throws {
    let settingsView = try sourceFile(named: "SettingsView.swift")
    let reviewsSection = try sourceFile(named: "SettingsReviewsSection.swift")
    let generalPane = try sourceFile(named: "SettingsReviewsGeneralPane.swift")
    let displayPane = try sourceFile(named: "SettingsReviewsDisplayPane.swift")
    let filesPane = try sourceFile(named: "SettingsReviewsFilesPane.swift")
    let timelinePane = try sourceFile(named: "SettingsReviewsTimelinePane.swift")

    #expect(
      settingsView.contains("ReviewsSettingsToolbarPicker(selection: $selectedReviewsPane)")
    )
    #expect(
      reviewsSection.contains("HarnessMonitorAccessibility.settingsReviewsPane(\"pane-picker\")")
    )
    #expect(reviewsSection.contains("SettingsReviewsGeneralPane("))
    #expect(reviewsSection.contains("SettingsReviewsDisplayPane("))
    #expect(reviewsSection.contains("SettingsReviewsFilesPane("))
    #expect(reviewsSection.contains("SettingsReviewsTimelinePane("))
    #expect(
      generalPane.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane(\"general\"))"
      )
    )
    #expect(
      displayPane.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane(\"display\"))"
      )
    )
    #expect(
      filesPane.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane(\"files\"))"
      )
    )
    #expect(
      timelinePane.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane(\"timeline\"))"
      )
    )
  }

  @Test("Settings reviews hidden timeline filters stay non-collapsible")
  func settingsReviewsHiddenTimelineFiltersStayNonCollapsible() throws {
    let reviewsSection = try sourceFile(named: "SettingsReviewsSection.swift")

    #expect(!reviewsSection.contains("DisclosureGroup(\"Hidden event types\")"))
    #expect(reviewsSection.contains("SettingsReviewsTimelinePane("))
    let timelinePane = try sourceFile(named: "SettingsReviewsTimelinePane.swift")
    #expect(timelinePane.contains("Text(\"Hidden Event Types\")"))
    #expect(timelinePane.contains("Toggle(\"Show activity timeline\""))
    #expect(timelinePane.contains("\"Show inline comments in activity timeline\""))
    #expect(timelinePane.contains("$draft.showActivityInlineComments"))
    #expect(timelinePane.contains("TextField(\"Search\", text: $hiddenKindsSearchText)"))
    #expect(timelinePane.contains("ForEach(filteredHiddenKinds, id: \\.rawValue)"))
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
    #expect(dashboardSidebarSessionsView.contains("Section(\"Recent sessions\")"))
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
}
