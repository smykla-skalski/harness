import HarnessMonitorKit
import SwiftUI

struct SettingsDependenciesSection: View {
  @Binding var navigationRequest: SettingsNavigationRequest?
  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedPreferences = ""
  @State private var draft = DashboardDependenciesPreferences()
  @State private var hasLoadedDraft = false

  init(navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)) {
    _navigationRequest = navigationRequest
  }

  var body: some View {
    Form {
      sourceScopeSection
      behaviorSection
      refreshSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesRoot)
    .task {
      loadDraftIfNeeded()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionsComposer
    }
  }

  private var sourceScopeSection: some View {
    Section {
      monitoredRepositoriesSummary
      TextField("Authors", text: $draft.authorsText)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesAuthorsField)
      TextField("Excluded Repositories", text: $draft.excludeRepositoriesText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDependenciesExcludedReposField
        )
    } header: {
      Text("Sources")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Configure shared monitored repositories in Settings > Repositories. Authors and \
        excluded repositories remain Dependencies-specific.
        """
      )
    }
  }

  private var monitoredRepositoriesSummary: some View {
    let repositories = draft.normalizedRepositories
    let legacyOrganizations = draft.normalizedOrganizations
    let repositoriesLabel =
      repositories.isEmpty
      ? "No repositories enabled"
      : "\(repositories.count) repositories enabled"
    let organizationsLabel =
      legacyOrganizations.isEmpty
      ? nil
      : "\(legacyOrganizations.count) legacy organization sources still active"

    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Monitored Repositories")
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(repositoriesLabel)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let organizationsLabel {
        Text(organizationsLabel)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Button("Open Repositories") {
        navigationRequest = SettingsNavigationRequest(target: .section(.repositories))
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .fixedSize(horizontal: true, vertical: true)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDependenciesRepositoriesButton
      )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesRepositoriesSummary)
  }

  private var behaviorSection: some View {
    Section {
      Picker("Merge Method", selection: $draft.mergeMethodRaw) {
        ForEach(TaskBoardGitHubMergeMethod.allCases) { method in
          Text(method.title).tag(method.rawValue)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesMergeMethodField)
      Toggle("Show label descriptions in pickers", isOn: $draft.showLabelDescriptions)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDependenciesShowLabelDescriptionsToggle
        )
      Picker("Frequently used labels", selection: $draft.frequentLabelsCount) {
        ForEach(Self.frequentLabelsCountRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDependenciesFrequentLabelsCountField
      )
    } header: {
      Text("Actions")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Merge method drives Merge and Auto actions. Toggle label descriptions to append the \
        repository-defined description next to each label name in the Add Label menus. The \
        Add Label dropdown surfaces the top N most-used labels per repository at the top.
        """
      )
    }
  }

  private var refreshSection: some View {
    Section {
      SettingsDurationPickerRow(
        title: "Refresh Interval",
        presets: Self.refreshPresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.refreshIntervalSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsDependenciesRefreshIntervalField
      )
      SettingsDurationPickerRow(
        title: "Cache Max Age",
        presets: Self.cachePresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.cacheMaxAgeSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsDependenciesCacheMaxAgeField
      )
    } header: {
      Text("Refresh & Cache")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("The route background refresh loop and cache TTL both use these values")
    }
  }

  static let minimumDurationSeconds: UInt64 = 30
  static let refreshPresetsSeconds: [UInt64] = [30, 60, 120, 300, 600, 900, 1_800, 3_600]
  static let cachePresetsSeconds: [UInt64] = [60, 300, 600, 900, 1_800, 3_600, 7_200, 21_600]
  static let frequentLabelsCountRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardDependenciesPreferences.minimumFrequentLabelsCount,
      upper: DashboardDependenciesPreferences.maximumFrequentLabelsCount
    )
  )

  private var actionsComposer: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Spacer(minLength: 0)
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HarnessMonitorWrapLayout(
            spacing: HarnessMonitorTheme.itemSpacing,
            lineSpacing: HarnessMonitorTheme.itemSpacing,
            rowAlignment: .trailing
          ) {
            HarnessMonitorActionButton(
              title: "Reload",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsDependenciesReloadButton
            ) {
              reloadDraft()
            }
            HarnessMonitorActionButton(
              title: "Save",
              tint: nil,
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsDependenciesSaveButton
            ) {
              saveDraft()
            }
          }
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingXL)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(.background)
  }

  private func loadDraftIfNeeded() {
    guard !hasLoadedDraft else { return }
    reloadDraft()
  }

  private func reloadDraft() {
    draft = DashboardDependenciesPreferences.decode(from: storedPreferences).normalized()
    hasLoadedDraft = true
  }

  private func saveDraft() {
    let normalized = draft.normalized()
    draft = normalized
    storedPreferences = normalized.encodedString
  }
}
