import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension SessionSwiftUISourceTests {
  @Test("Settings retained live-store roots only observe while active")
  func settingsRetainedLiveStoreRootsOnlyObserveWhileActive() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsView.swift")
    let mcpSource = try sourceFile(at: "Views/Settings/SettingsMCPSection.swift")
    let codexSource = try sourceFile(at: "Views/Settings/SettingsCodexSection.swift")
    let databaseSource = try sourceFile(at: "Views/Settings/SettingsDatabaseSection.swift")
    let foldersSource = try sourceFile(at: "Views/Settings/AuthorizedFoldersSection.swift")
    let generalSource = try sourceFile(at: "Views/Settings/SettingsGeneralSection.swift")
    let loggingSource = try sourceFile(at: "Views/Settings/SettingsLoggingSection.swift")
    let actionButtonsSource = try sourceFile(at: "Views/Settings/SettingsActionButtons.swift")
    let focusModeSource = try sourceFile(at: "Views/Settings/SettingsFocusModeSection.swift")
    let bannersSource = try sourceFile(at: "Views/Settings/SettingsBannersSection.swift")
    let appearanceSource = try sourceFile(at: "Views/Settings/SettingsAppearanceSection.swift")
    let markdownSource = try sourceFile(at: "Views/Settings/SettingsMarkdownSection.swift")
    let notificationsSource = try sourceFile(
      at: "Views/Settings/SettingsNotificationsSection.swift"
    )
    let voiceSource = try sourceFile(at: "Views/Settings/SettingsVoiceSection.swift")
    let mobileSource = try sourceFile(at: "Views/Settings/SettingsMobileSection.swift")
    let taskBoardSource = try sourceFile(at: "Views/Settings/SettingsTaskBoardSection.swift")
    let repositoriesSource = try sourceFile(at: "Views/Settings/SettingsRepositoriesSection.swift")
    let reviewsSource = try sourceFile(at: "Views/Settings/SettingsReviewsSection.swift")
    let reviewsGeneralSource = try sourceFile(at: "Views/Settings/SettingsReviewsGeneralPane.swift")
    let reviewsDisplaySource = try sourceFile(at: "Views/Settings/SettingsReviewsDisplayPane.swift")
    let reviewsFilesPaneSource = try sourceFile(at: "Views/Settings/SettingsReviewsFilesPane.swift")
    let reviewsTimelineSource =
      try sourceFile(at: "Views/Settings/SettingsReviewsTimelinePane.swift")
    let secretsSource = try sourceFile(at: "Views/Settings/SettingsSecretsSection.swift")
    let policiesSource = try sourceFile(at: "Views/Settings/SettingsPoliciesSection.swift")
    let supervisorSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorSection.swift"
    )
    let supervisorRulesSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorRulesPane.swift"
    )
    let supervisorNotificationsSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorNotificationsPane.swift"
    )
    let supervisorBackgroundSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorBackgroundPane.swift"
    )
    let supervisorAuditSource = try sourceFile(
      at: "Views/Settings/Supervisor/SettingsSupervisorAuditPane.swift"
    )

    #expect(
      source.contains(
        "SettingsGeneralSectionRoot(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      source.contains(
        "SettingsNotificationsSection(\n        notifications: notifications,\n"
          + "        isActive: section == selectedSection\n      )"
      )
    )
    #expect(
      source.contains(
        "let activeSnapshot = isActive ? SettingsGeneralSnapshot(store: store) : nil"
      )
    )
    #expect(source.contains("SettingsConnectionSectionRoot("))
    #expect(source.contains("isActive: section == selectedSection"))
    #expect(source.contains("SettingsFocusModeSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsBannersSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsAppearanceSection("))
    #expect(source.contains("SettingsMarkdownSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsVoiceSection(isActive: section == selectedSection)"))
    #expect(source.contains("SettingsMobileSection("))
    #expect(source.contains("SettingsTaskBoardSection("))
    #expect(source.contains("SettingsRepositoriesSection("))
    #expect(source.contains("SettingsReviewsSection("))
    #expect(source.contains("@State private var selectedReviewsPane: ReviewsPaneKey = .general"))
    #expect(source.contains("SettingsSecretsSection("))
    #expect(source.contains("SettingsPoliciesSection(isActive: section == selectedSection)"))
    #expect(source.contains("@State private var cachedSnapshot: SettingsConnectionSnapshot?"))
    #expect(
      source.contains(
        "let activeSnapshot = isActive ? SettingsConnectionSnapshot(store: store) : nil"
      )
    )
    #expect(
      source.contains(
        "let activeInput = isActive ? SettingsDiagnosticsSnapshotInput(store: store) : nil"
      )
    )
    #expect(
      source.contains(
        "if isActive {\n        if let snapshot = activeSnapshot ?? cachedSnapshot"
      )
    )
    #expect(source.contains("let displayedInput = isActive ? activeInput ?? preparedInput : nil"))
    #expect(source.contains("} else {\n        Color.clear\n      }"))
    #expect(source.contains(".task(id: activeInput)"))
    #expect(
      source.contains(
        "SettingsHostBridgeSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      source.contains("SettingsMCPSection(store: store, isActive: section == selectedSection)")
    )
    #expect(
      source.contains(
        "AuthorizedFoldersSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      source.contains(
        "SettingsDatabaseSection(store: store, isActive: section == selectedSection)"
      )
    )
    #expect(
      mcpSource.contains(
        "let activeSnapshot = isActive ? SettingsMCPSnapshot(store: store) : nil"
      )
    )
    #expect(mcpSource.contains(".task(id: activeSnapshot)"))
    #expect(
      codexSource.contains(
        "let activeSnapshot = isActive ? SettingsHostBridgeSnapshot(store: store) : nil"
      )
    )
    #expect(codexSource.contains(".task(id: activeSnapshot)"))
    #expect(
      databaseSource.contains(
        "let activeHealthSnapshot = isActive ? SettingsDatabaseHealthSnapshot(store: store) : nil"
      )
    )
    #expect(databaseSource.contains(".task(id: activeHealthSnapshot)"))
    #expect(
      foldersSource.contains(
        "let activeBookmarkStore = isActive ? store.bookmarkStore : nil"
      )
    )
    #expect(foldersSource.contains(".task(id: isActive)"))
    #expect(generalSource.contains("public struct SettingsGeneralLiveState"))
    #expect(generalSource.contains("SettingsLoggingSection("))
    #expect(generalSource.contains("daemonLogLevel: liveState.daemonLogLevel"))
    #expect(generalSource.contains("daemonOwnership: liveState.daemonOwnership"))
    #expect(!loggingSource.contains("public let store: HarnessMonitorStore"))
    #expect(!actionButtonsSource.contains("let store: HarnessMonitorStore"))
    for retainedSource in [
      focusModeSource,
      bannersSource,
      appearanceSource,
      markdownSource,
      notificationsSource,
      voiceSource,
      mobileSource,
      policiesSource,
      mcpSource,
      codexSource,
      databaseSource,
      foldersSource,
    ] {
      #expect(retainedSource.contains("isActive"))
      #expect(retainedSource.contains("if isActive {\n      activeBody"))
      #expect(retainedSource.contains("Color.clear"))
    }
    #expect(appearanceSource.contains(".task(id: isActive)"))
    #expect(markdownSource.contains(".task(id: isActive)"))
    #expect(voiceSource.contains(".task(id: isActive)"))
    #expect(voiceSource.contains("guard isActive else { return }"))
    #expect(
      notificationsSource.contains(
        "let activeSnapshot = isActive ? SettingsNotificationsSnapshot("
          + "notifications: notifications) : nil"
      )
    )
    #expect(notificationsSource.contains(".task(id: isActive)"))
    #expect(notificationsSource.contains(".task(id: activeSnapshot)"))
    #expect(notificationsSource.contains("private struct SettingsNotificationsSnapshot"))
    #expect(notificationsSource.contains("NotificationsStatusSection(snapshot: snapshot)"))
    #expect(
      !notificationsSource.contains(
        "NotificationsStatusSection(notifications: notifications)"
      )
    )
    #expect(taskBoardSource.contains("let isActive: Bool"))
    #expect(taskBoardSource.contains("if isActive {\n      activeBody"))
    #expect(taskBoardSource.contains(".task(id: isActive)"))
    #expect(repositoriesSource.contains("let isActive: Bool"))
    #expect(repositoriesSource.contains("if isActive {\n      activeBody"))
    #expect(repositoriesSource.contains(".task(id: isActive)"))
    #expect(
      source.contains(
        "SettingsReviewsSection(\n        isActive: section == selectedSection,\n"
          + "        navigationRequest: $navigationRequest,\n"
          + "        selectedPane: $selectedReviewsPane\n      )"
      )
    )
    #expect(source.contains("ReviewsSettingsToolbarPicker(selection: $selectedReviewsPane)"))
    #expect(reviewsSource.contains("@Binding var selectedPane: ReviewsPaneKey"))
    #expect(reviewsSource.contains("ReviewsRetainedPaneLayout(selectedPane: selectedPane)"))
    #expect(reviewsSource.contains("@State private var visitedPanes: Set<ReviewsPaneKey> = []"))
    #expect(reviewsSource.contains("SettingsReviewsGeneralPane("))
    #expect(reviewsSource.contains("SettingsReviewsDisplayPane("))
    #expect(reviewsSource.contains("SettingsReviewsFilesPane("))
    #expect(reviewsSource.contains("SettingsReviewsTimelinePane("))
    for reviewsPaneSource in [
      reviewsGeneralSource,
      reviewsDisplaySource,
      reviewsFilesPaneSource,
      reviewsTimelineSource,
    ] {
      #expect(reviewsPaneSource.contains("let isActive: Bool"))
      #expect(reviewsPaneSource.contains("if isActive {\n      activeBody"))
      #expect(reviewsPaneSource.contains("Color.clear"))
    }
    #expect(secretsSource.contains("let isActive: Bool"))
    #expect(secretsSource.contains("if isActive {\n      activeBody"))
    #expect(secretsSource.contains(".task(id: isActive)"))
    #expect(source.contains("SettingsSupervisorSection("))
    #expect(
      source.contains(
        "isActive: section == selectedSection,\n        selectedPane: $selectedSupervisorPane"
      )
    )
    #expect(supervisorSource.contains("if isActive {\n      activeBody"))
    #expect(supervisorSource.contains("} else {\n      Color.clear\n    }"))
    #expect(supervisorSource.contains("let isPaneActive = isActive && pane == selectedPane"))
    #expect(
      supervisorSource.contains(
        "SettingsSupervisorRulesPane(store: store, isActive: isPaneActive)"
      )
    )
    #expect(
      supervisorSource.contains(
        "SettingsSupervisorAuditPane(store: store, isActive: isPaneActive)"
      )
    )
    #expect(
      supervisorRulesSource.contains(
        "guard isActive else { return }\n      await reloadRows()"
      )
    )
    #expect(
      supervisorNotificationsSource.contains(
        "guard isActive else { return }\n      await notifications.refreshStatus()"
      )
    )
    #expect(supervisorBackgroundSource.contains("if isActive {"))
    #expect(supervisorAuditSource.contains("if isActive {"))
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
}
