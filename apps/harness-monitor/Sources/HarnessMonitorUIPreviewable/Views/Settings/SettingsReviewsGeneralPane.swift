import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsGeneralPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences
  @Binding var navigationRequest: SettingsNavigationRequest?

  init(
    draft: Binding<DashboardReviewsPreferences>,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil),
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
    _navigationRequest = navigationRequest
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      sourceScopeSection
      behaviorSection
      refreshSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane("general"))
  }

  private var sourceScopeSection: some View {
    Section {
      monitoredRepositoriesSummary
      TextField("Excluded Repositories", text: $draft.excludeRepositoriesText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsExcludedReposField
        )
      Toggle("Expand organizations to repositories", isOn: $draft.expandOrganizations)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDepsExpandOrganizationsToggle
        )
    } header: {
      Text("Sources")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Configure shared monitored repositories in Settings > Repositories. \
        Excluded repositories remain Reviews-specific. When organization expansion is \
        on, each org resolves to its repositories so per-repo syncs can stagger across the \
        schedule.
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
        HarnessMonitorAccessibility.settingsReviewsRepositoriesButton
      )
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsRepositoriesSummary)
  }

  private var behaviorSection: some View {
    Section {
      Picker("Merge Method", selection: $draft.mergeMethodRaw) {
        ForEach(TaskBoardGitHubMergeMethod.allCases) { method in
          Text(method.title).tag(method.rawValue)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsMergeMethodField)
      Toggle("Show label descriptions in pickers", isOn: $draft.showLabelDescriptions)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsDepsShowLabelDescriptionsToggle
        )
      Picker("Frequently used labels", selection: $draft.frequentLabelsCount) {
        ForEach(Self.frequentLabelsCountRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDepsFrequentLabelsCountField
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
        title: "Refresh Each Repository Every",
        presets: Self.refreshPresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.perRepositoryIntervalSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsReviewsPerRepoIntervalField
      )
      Picker("Max Concurrent Fetches", selection: $draft.maxConcurrentRepositoryFetches) {
        ForEach(Self.maxConcurrentRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsMaxConcurrentField
      )
      SettingsDurationPickerRow(
        title: "Cache Max Age",
        presets: Self.cachePresetsSeconds,
        minSeconds: Self.minimumDurationSeconds,
        seconds: $draft.cacheMaxAgeSeconds,
        pickerAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsReviewsCacheMaxAgeField
      )
    } header: {
      Text("Sync Schedule")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Each repository is fetched on its own timer. With 12 repositories and a 5-minute \
        interval, expect a sync roughly every 25 seconds.
        """
      )
    }
  }

  private static let minimumDurationSeconds: UInt64 = 30
  private static let refreshPresetsSeconds: [UInt64] =
    [30, 60, 120, 300, 600, 900, 1_800, 3_600]
  private static let cachePresetsSeconds: [UInt64] =
    [60, 300, 600, 900, 1_800, 3_600, 7_200, 21_600]
  private static let maxConcurrentRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumConcurrentRepositoryFetches,
      upper: DashboardReviewsPreferences.maximumConcurrentRepositoryFetches
    )
  )
  private static let frequentLabelsCountRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumFrequentLabelsCount,
      upper: DashboardReviewsPreferences.maximumFrequentLabelsCount
    )
  )
}
