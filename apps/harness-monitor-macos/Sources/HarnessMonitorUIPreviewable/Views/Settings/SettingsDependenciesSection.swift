import HarnessMonitorKit
import SwiftUI

struct SettingsDependenciesSection: View {
  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedPreferences = ""
  @State private var draft = DashboardDependenciesPreferences()
  @State private var hasLoadedDraft = false

  init() {}

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
      TextField("Authors", text: $draft.authorsText)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesAuthorsField)
      TextField("Organizations", text: $draft.organizationsText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDependenciesOrganizationsField
        )
      TextField("Repositories", text: $draft.repositoriesText)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesRepositoriesField)
      TextField("Excluded Repositories", text: $draft.excludeRepositoriesText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDependenciesExcludedRepositoriesField
        )
    } header: {
      Text("Sources")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Separate multiple authors, organizations, or repositories with commas or new lines.")
    }
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
    } header: {
      Text("Actions")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("This merge method is used for Merge and Auto actions in the Dependencies dashboard.")
    }
  }

  private var refreshSection: some View {
    Section {
      TextField(
        "Refresh Interval (seconds)",
        value: $draft.refreshIntervalSeconds,
        format: .number
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDependenciesRefreshIntervalField
      )
      TextField(
        "Cache Max Age (seconds)",
        value: $draft.cacheMaxAgeSeconds,
        format: .number
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsDependenciesCacheMaxAgeField)
    } header: {
      Text("Refresh & Cache")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("The route background refresh loop and cache TTL both use these values.")
    }
  }

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
