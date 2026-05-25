import HarnessMonitorKit
import SwiftUI

/// Holds per-section editable state (task-board form, diagnostics snapshot
/// cache) outside of `SettingsView`, and lazy-mounts each section into a
/// retained layout so subsequent visits don't pay SwiftUI's view-tree rebuild
/// cost.
///
/// Retention semantics:
/// - First visit to a section: full build cost.
/// - Any subsequent visit: instant. The view tree stays mounted, but inactive
///   sections are not measured or placed. ScrollView state preserved.
/// - Each retained section gets its own `\.settingsScrollRestorationSection`
///   env override so SettingsScrollRestorationModifier targets the right
///   per-section persisted offset.
///
/// Trade-off: sections with `.task { await refresh() }` only refresh on first
/// visit per Settings session.
struct SettingsDetailSwitch: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  let mobilePairingContent: (@MainActor @Sendable () -> AnyView)?
  @Binding var themeMode: HarnessMonitorThemeMode
  let selectedSection: SettingsSection
  @Binding var navigationRequest: SettingsNavigationRequest?
  @Binding var selectedSupervisorPane: SupervisorPaneKey
  @Binding var selectedReviewsPane: ReviewsPaneKey
  @State private var taskBoardFormState = TaskBoardSettingsFormState()
  @State private var preparedDiagnosticsInput: SettingsDiagnosticsSnapshotInput?
  @State private var preparedDiagnosticsSnapshot: SettingsDiagnosticsSnapshot?
  @State private var visitedSections: Set<SettingsSection> = []

  var body: some View {
    SettingsRetainedSectionLayout(selectedSection: selectedSection) {
      ForEach(SettingsSection.allCases, id: \.self) { section in
        if visitedSections.contains(section) {
          let isSelected = section == selectedSection
          SettingsRetainedSectionHost(
            section: section,
            isSelected: isSelected,
            isRestorationSuspended: isSelected && navigationRequest?.target.section == section
          ) {
            sectionContent(section)
          }
          .equatable()
          .layoutValue(key: SettingsRetainedSectionKey.self, value: section)
        }
      }
    }
    .harnessGlassContainerScope()
    .harnessMonitorBackgroundExtensionEffect()
    .onChange(of: selectedSection, initial: true) { _, newValue in
      visit(newValue)
    }
  }

  private func visit(_ section: SettingsSection) {
    guard !visitedSections.contains(section) else {
      return
    }
    visitedSections.insert(section)
  }

  @ViewBuilder
  private func sectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .general, .focusMode, .banners, .appearance, .markdown, .notifications, .voice,
      .connection, .mobile:
      primarySectionContent(section)
    case .taskBoard, .repositories, .reviews, .secrets:
      taskBoardSectionContent(section)
    case .policies, .codex, .mcp, .authorizedFolders:
      integrationSectionContent(section)
    case .supervisor, .database, .diagnostics:
      operationsSectionContent(section)
    }
  }

  @ViewBuilder
  private func primarySectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .general:
      SettingsGeneralSectionRoot(store: store, isActive: section == selectedSection)
    case .focusMode:
      SettingsFocusModeSection(isActive: section == selectedSection)
    case .banners:
      SettingsBannersSection(isActive: section == selectedSection)
    case .appearance:
      SettingsAppearanceSection(
        themeMode: $themeMode,
        isActive: section == selectedSection
      )
    case .markdown:
      SettingsMarkdownSection(isActive: section == selectedSection)
    case .notifications:
      SettingsNotificationsSection(
        notifications: notifications,
        isActive: section == selectedSection
      )
    case .voice:
      SettingsVoiceSection(isActive: section == selectedSection)
    case .connection:
      SettingsConnectionSectionRoot(
        store: store,
        isActive: section == selectedSection
      )
    case .mobile:
      SettingsMobileSection(
        pairingContent: mobilePairingContent,
        isActive: section == selectedSection
      )
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func taskBoardSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .taskBoard:
      SettingsTaskBoardSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection,
        navigationRequest: $navigationRequest
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .repositories:
      SettingsRepositoriesSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .reviews:
      SettingsReviewsSection(
        isActive: section == selectedSection,
        navigationRequest: $navigationRequest,
        selectedPane: $selectedReviewsPane
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .secrets:
      SettingsSecretsSection(
        store: store,
        formState: $taskBoardFormState,
        isActive: section == selectedSection
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func integrationSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .policies:
      SettingsPoliciesSection(isActive: section == selectedSection)
    case .codex:
      SettingsHostBridgeSection(store: store, isActive: section == selectedSection)
    case .mcp:
      SettingsMCPSection(store: store, isActive: section == selectedSection)
    case .authorizedFolders:
      AuthorizedFoldersSection(store: store, isActive: section == selectedSection)
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func operationsSectionContent(_ section: SettingsSection) -> some View {
    switch section {
    case .supervisor:
      SettingsSupervisorSection(
        store: store,
        notifications: notifications,
        isActive: section == selectedSection,
        selectedPane: $selectedSupervisorPane
      )
    case .database:
      SettingsDatabaseSection(store: store, isActive: section == selectedSection)
    case .diagnostics:
      SettingsDiagnosticsSectionRoot(
        store: store,
        isActive: section == selectedSection,
        preparedInput: $preparedDiagnosticsInput,
        preparedSnapshot: $preparedDiagnosticsSnapshot
      )
    default:
      EmptyView()
    }
  }
}
