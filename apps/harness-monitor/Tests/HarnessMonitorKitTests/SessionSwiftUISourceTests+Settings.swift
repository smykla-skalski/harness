import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

private struct SettingsRetainedSources {
  let viewSource: String
  let source: String
  let supportSource: String
  let mcpSource: String
  let codexSource: String
  let databaseSource: String
  let foldersSource: String
  let generalSource: String
  let loggingSource: String
  let actionButtonsSource: String
  let focusModeSource: String
  let bannersSource: String
  let appearanceSource: String
  let markdownSource: String
  let notificationsSource: String
  let voiceSource: String
  let mobileSource: String
  let taskBoardSource: String
  let repositoriesSource: String
  let reviewsSource: String
  let reviewsGeneralSource: String
  let reviewsDisplaySource: String
  let reviewsFilesPaneSource: String
  let reviewsTimelineSource: String
  let secretsSource: String
  let policiesSource: String
  let supervisorSource: String
  let supervisorRulesSource: String
  let supervisorNotificationsSource: String
  let supervisorBackgroundSource: String
  let supervisorAuditSource: String
}

extension SessionSwiftUISourceTests {
  @Test("Settings retained live-store roots only observe while active")
  func settingsRetainedLiveStoreRootsOnlyObserveWhileActive() throws {
    let sources = try loadSettingsRetainedSources()

    expectSettingsViewRetainsOnlyActiveSections(in: sources)
    expectRetainedSettingsSourcesGateOnIsActive(in: sources)
    expectReviewsRetentionUsesActivePaneSources(in: sources)
    expectSupervisorRetentionUsesActivePaneSources(in: sources)
  }

  @Test("Decision rows keep deadline churn scoped to the deadline chip")
  func decisionRowsKeepTimelineTicksOutOfTheRowBody() throws {
    let rowSource = try sourceFile(at: "Views/Decisions/DecisionRow.swift")

    #expect(!rowSource.contains("TimelineView("))
    #expect(rowSource.contains("let showsDeadline = acpPayload?.expiresAtDate != nil"))
    #expect(rowSource.contains("referenceDate: nil"))
    #expect(!rowSource.contains("deadlineStatus("))
  }

  @Test("Decision live tick keeps duplicate quarantined rules off self identity")
  func decisionLiveTickKeepsDuplicateRuleIDsOffSelfIdentity() throws {
    let source = try sourceFile(at: "Views/Decisions/DecisionsLiveTickView.swift")

    #expect(source.contains("private var indexedRuleIDs"))
    #expect(source.contains("ForEach(indexedRuleIDs, id: \\.offset)"))
    #expect(!source.contains("ForEach(ruleIDs, id: \\.self)"))
  }

  private func loadSettingsRetainedSources() throws -> SettingsRetainedSources {
    SettingsRetainedSources(
      viewSource: try sourceFile(at: "Views/Settings/SettingsView.swift"),
      source: try sourceFile(at: "Views/Settings/SettingsView+SectionSwitch.swift"),
      supportSource: try sourceFile(at: "Views/Settings/SettingsView+Support.swift"),
      mcpSource: try sourceFile(at: "Views/Settings/SettingsMCPSection.swift"),
      codexSource: try sourceFile(at: "Views/Settings/SettingsCodexSection.swift"),
      databaseSource: try sourceFile(at: "Views/Settings/SettingsDatabaseSection.swift"),
      foldersSource: try sourceFile(at: "Views/Settings/AuthorizedFoldersSection.swift"),
      generalSource: try sourceFile(at: "Views/Settings/SettingsGeneralSection.swift"),
      loggingSource: try sourceFile(at: "Views/Settings/SettingsLoggingSection.swift"),
      actionButtonsSource: try sourceFile(at: "Views/Settings/SettingsActionButtons.swift"),
      focusModeSource: try sourceFile(at: "Views/Settings/SettingsFocusModeSection.swift"),
      bannersSource: try sourceFile(at: "Views/Settings/SettingsBannersSection.swift"),
      appearanceSource: try sourceFile(at: "Views/Settings/SettingsAppearanceSection.swift"),
      markdownSource: try sourceFile(at: "Views/Settings/SettingsMarkdownSection.swift"),
      notificationsSource: try sourceFile(at: "Views/Settings/SettingsNotificationsSection.swift"),
      voiceSource: try sourceFile(at: "Views/Settings/SettingsVoiceSection.swift"),
      mobileSource: try sourceFile(at: "Views/Settings/SettingsMobileSection.swift"),
      taskBoardSource: try sourceFile(at: "Views/Settings/SettingsTaskBoardSection.swift"),
      repositoriesSource: try sourceFile(at: "Views/Settings/SettingsRepositoriesSection.swift"),
      reviewsSource: try sourceFile(at: "Views/Settings/SettingsReviewsSection.swift"),
      reviewsGeneralSource: try sourceFile(at: "Views/Settings/SettingsReviewsGeneralPane.swift"),
      reviewsDisplaySource: try sourceFile(at: "Views/Settings/SettingsReviewsDisplayPane.swift"),
      reviewsFilesPaneSource: try sourceFile(at: "Views/Settings/SettingsReviewsFilesPane.swift"),
      reviewsTimelineSource: try sourceFile(at: "Views/Settings/SettingsReviewsTimelinePane.swift"),
      secretsSource: try sourceFile(at: "Views/Settings/SettingsSecretsSection.swift"),
      policiesSource: try sourceFile(at: "Views/Settings/SettingsPoliciesSection.swift"),
      supervisorSource: try sourceFile(
        at: "Views/Settings/Supervisor/SettingsSupervisorSection.swift"
      ),
      supervisorRulesSource: try sourceFile(
        at: "Views/Settings/Supervisor/SettingsSupervisorRulesPane.swift"
      ),
      supervisorNotificationsSource: try sourceFile(
        at: "Views/Settings/Supervisor/SettingsSupervisorNotificationsPane.swift"
      ),
      supervisorBackgroundSource: try sourceFile(
        at: "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift"
      ),
      supervisorAuditSource: try sourceFile(
        at: "Views/Settings/Supervisor/SettingsSupervisorAuditPane.swift"
      )
    )
  }

  private func expectSettingsViewRetainsOnlyActiveSections(in sources: SettingsRetainedSources) {
    expectSettingsViewRetainsSectionRoots(in: sources)
    expectSettingsViewRetainsLiveSnapshots(in: sources)
  }

  private func expectSettingsViewRetainsSectionRoots(in sources: SettingsRetainedSources) {
    #expect(
      sources.source.contains(
        "SettingsGeneralSectionRoot(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      sources.source.contains(
        "SettingsNotificationsSection(\n        notifications: notifications,\n"
          + "        isActive: section == selectedSection\n      )"
      )
    )
    #expect(
      sources.supportSource.contains(
        "let activeSnapshot = isActive ? SettingsGeneralSnapshot(store: store) : nil"
      )
    )
    #expect(sources.source.contains("SettingsConnectionSectionRoot("))
    #expect(sources.source.contains("isActive: section == selectedSection"))
    #expect(
      sources.source.contains("SettingsFocusModeSection(isActive: section == selectedSection)")
    )
    #expect(
      sources.source.contains("SettingsBannersSection(isActive: section == selectedSection)")
    )
    #expect(sources.source.contains("SettingsAppearanceSection("))
    #expect(
      sources.source.contains("SettingsMarkdownSection(isActive: section == selectedSection)")
    )
    #expect(
      sources.source.contains("SettingsVoiceSection(isActive: section == selectedSection)")
    )
    #expect(sources.source.contains("SettingsMobileSection("))
    #expect(sources.source.contains("SettingsTaskBoardSection("))
    #expect(sources.source.contains("SettingsRepositoriesSection("))
    #expect(sources.source.contains("SettingsReviewsSection("))
    #expect(
      sources.viewSource.contains("@State private var selectedReviewsPane: ReviewsPaneKey = .general")
    )
    #expect(sources.source.contains("SettingsSecretsSection("))
    #expect(
      sources.source.contains("SettingsPoliciesSection(isActive: section == selectedSection)")
    )
    #expect(
      sources.supportSource.contains("@State private var cachedSnapshot: SettingsConnectionSnapshot?")
    )
  }

  private func expectSettingsViewRetainsLiveSnapshots(in sources: SettingsRetainedSources) {
    #expect(
      sources.supportSource.contains(
        "let activeSnapshot = isActive ? SettingsConnectionSnapshot(store: store) : nil"
      )
    )
    #expect(
      sources.supportSource.contains(
        "let activeInput = isActive ? SettingsDiagnosticsSnapshotInput(store: store) : nil"
      )
    )
    #expect(
      sources.supportSource.contains(
        "if isActive {\n        if let snapshot = activeSnapshot ?? cachedSnapshot"
      )
    )
    #expect(
      sources.supportSource.contains(
        "let displayedInput = isActive ? activeInput ?? preparedInput : nil"
      )
    )
    #expect(sources.supportSource.contains("} else {\n        Color.clear\n      }"))
    #expect(sources.supportSource.contains(".task(id: activeInput)"))
    #expect(
      sources.source.contains(
        "SettingsHostBridgeSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      sources.source.contains(
        "SettingsMCPSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      sources.source.contains(
        "AuthorizedFoldersSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      sources.source.contains(
        "SettingsDatabaseSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      sources.mcpSource.contains(
        "let activeSnapshot = isActive ? SettingsMCPSnapshot(store: store) : nil"
      )
    )
    #expect(sources.mcpSource.contains(".task(id: activeSnapshot)"))
    #expect(
      sources.codexSource.contains(
        "let activeSnapshot = isActive ? SettingsHostBridgeSnapshot(store: store) : nil"
      )
    )
    #expect(sources.codexSource.contains(".task(id: activeSnapshot)"))
    #expect(
      sources.databaseSource.contains(
        "let activeHealthSnapshot = isActive ? SettingsDatabaseHealthSnapshot(store: store) : nil"
      )
    )
    #expect(sources.databaseSource.contains(".task(id: activeHealthSnapshot)"))
    #expect(
      sources.foldersSource.contains(
        "let activeBookmarkStore = isActive ? store.bookmarkStore : nil"
      )
    )
    #expect(sources.foldersSource.contains(".task(id: isActive)"))
    #expect(sources.generalSource.contains("public struct SettingsGeneralLiveState"))
    #expect(sources.generalSource.contains("SettingsLoggingSection("))
    #expect(sources.generalSource.contains("daemonLogLevel: liveState.daemonLogLevel"))
    #expect(sources.generalSource.contains("daemonOwnership: liveState.daemonOwnership"))
    #expect(!sources.loggingSource.contains("public let store: HarnessMonitorStore"))
    #expect(!sources.actionButtonsSource.contains("let store: HarnessMonitorStore"))
  }

  private func expectRetainedSettingsSourcesGateOnIsActive(in sources: SettingsRetainedSources) {
    for retainedSource in [
      sources.focusModeSource,
      sources.bannersSource,
      sources.appearanceSource,
      sources.markdownSource,
      sources.notificationsSource,
      sources.voiceSource,
      sources.mobileSource,
      sources.policiesSource,
      sources.mcpSource,
      sources.codexSource,
      sources.databaseSource,
      sources.foldersSource,
    ] {
      #expect(retainedSource.contains("isActive"))
      #expect(retainedSource.contains("if isActive {\n      activeBody"))
      #expect(retainedSource.contains("Color.clear"))
    }
    #expect(sources.appearanceSource.contains(".task(id: isActive)"))
    #expect(sources.markdownSource.contains(".task(id: isActive)"))
    #expect(sources.voiceSource.contains(".task(id: isActive)"))
    #expect(sources.voiceSource.contains("guard isActive else { return }"))
    #expect(
      sources.notificationsSource.contains(
        "let activeSnapshot = isActive ? SettingsNotificationsSnapshot("
          + "notifications: notifications) : nil"
      )
    )
    #expect(sources.notificationsSource.contains(".task(id: isActive)"))
    #expect(sources.notificationsSource.contains(".task(id: activeSnapshot)"))
    #expect(sources.notificationsSource.contains("cachedSnapshot: SettingsNotificationsSnapshot?"))
    #expect(sources.notificationsSource.contains("NotificationsStatusSection(snapshot: snapshot)"))
    #expect(
      !sources.notificationsSource.contains(
        "NotificationsStatusSection(notifications: notifications)"
      )
    )
    #expect(sources.taskBoardSource.contains("let isActive: Bool"))
    #expect(sources.taskBoardSource.contains("if isActive {\n      activeBody"))
    #expect(sources.taskBoardSource.contains(".task(id: isActive)"))
    #expect(sources.repositoriesSource.contains("let isActive: Bool"))
    #expect(sources.repositoriesSource.contains("if isActive {\n      activeBody"))
    #expect(sources.repositoriesSource.contains(".task(id: isActive)"))
    #expect(sources.secretsSource.contains("let isActive: Bool"))
    #expect(sources.secretsSource.contains("if isActive {\n      activeBody"))
    #expect(sources.secretsSource.contains(".task(id: isActive)"))
  }

  private func expectReviewsRetentionUsesActivePaneSources(in sources: SettingsRetainedSources) {
    #expect(
      sources.source.contains(
        "SettingsReviewsSection(\n        isActive: section == selectedSection,\n"
          + "        navigationRequest: $navigationRequest,\n"
          + "        selectedPane: $selectedReviewsPane\n      )"
      )
    )
    #expect(
      sources.viewSource.contains("ReviewsSettingsToolbarPicker(selection: $selectedReviewsPane)")
    )
    #expect(sources.reviewsSource.contains("@Binding var selectedPane: ReviewsPaneKey"))
    #expect(sources.reviewsSource.contains("ReviewsRetainedPaneLayout(selectedPane: selectedPane)"))
    #expect(
      sources.reviewsSource.contains("@State private var visitedPanes: Set<ReviewsPaneKey> = []")
    )
    #expect(sources.reviewsSource.contains("SettingsReviewsGeneralPane("))
    #expect(sources.reviewsSource.contains("SettingsReviewsDisplayPane("))
    #expect(sources.reviewsSource.contains("SettingsReviewsFilesPane("))
    #expect(sources.reviewsSource.contains("SettingsReviewsTimelinePane("))
    for reviewsPaneSource in [
      sources.reviewsGeneralSource,
      sources.reviewsDisplaySource,
      sources.reviewsFilesPaneSource,
      sources.reviewsTimelineSource,
    ] {
      #expect(reviewsPaneSource.contains("let isActive: Bool"))
      #expect(reviewsPaneSource.contains("if isActive {\n      activeBody"))
      #expect(reviewsPaneSource.contains("Color.clear"))
    }
  }

  private func expectSupervisorRetentionUsesActivePaneSources(in sources: SettingsRetainedSources) {
    #expect(sources.source.contains("SettingsSupervisorSection("))
    #expect(
      sources.source.contains(
        "isActive: section == selectedSection,\n        selectedPane: $selectedSupervisorPane"
      )
    )
    #expect(sources.supervisorSource.contains("if isActive {\n      activeBody"))
    #expect(sources.supervisorSource.contains("} else {\n      Color.clear\n    }"))
    #expect(
      sources.supervisorSource.contains("let isPaneActive = isActive && pane == selectedPane")
    )
    #expect(
      sources.supervisorSource.contains(
        "SettingsSupervisorRulesPane(store: store, isActive: isPaneActive)"
      )
    )
    #expect(
      sources.supervisorSource.contains(
        "SettingsSupervisorAuditPane(store: store, isActive: isPaneActive)"
      )
    )
    #expect(
      sources.supervisorRulesSource.contains(
        "guard isActive else { return }\n      await reloadRows()"
      )
    )
    #expect(
      sources.supervisorNotificationsSource.contains(
        "guard isActive else { return }\n      await notifications.refreshStatus()"
      )
    )
    #expect(sources.supervisorBackgroundSource.contains("if isActive {"))
    #expect(sources.supervisorAuditSource.contains("if isActive {"))
  }
}
