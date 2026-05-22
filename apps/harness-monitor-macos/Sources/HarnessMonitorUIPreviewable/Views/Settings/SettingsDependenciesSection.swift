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
      Section {
        SettingsDependenciesFilesSection(draft: $draft)
      } header: {
        Text("Files").harnessNativeFormSectionHeader()
      }
      timelineSection
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
        Configure shared monitored repositories in Settings > Repositories. Authors and \
        excluded repositories remain Dependencies-specific. When organization expansion is \
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

  private var timelineSection: some View {
    Section {
      Toggle("Show activity timeline", isOn: $draft.showActivityTimeline)
      Stepper(
        "Initial page size: \(draft.timelineInitialPageSize)",
        value: $draft.timelineInitialPageSize,
        in: Self.timelinePageSizeRange,
        step: 10
      )
      Stepper(
        "Load older batch size: \(draft.timelineLoadOlderBatchSize)",
        value: $draft.timelineLoadOlderBatchSize,
        in: Self.timelinePageSizeRange,
        step: 10
      )
      Toggle(
        "Auto-collapse heavy review threads",
        isOn: $draft.timelineAutoCollapseHeavyReviewThreads
      )
      DisclosureGroup("Hidden event types") {
        ForEach(DependencyUpdateTimelineKind.allCases, id: \.self) { kind in
          Toggle(
            kindDisplayName(kind),
            isOn: Binding(
              get: { draft.timelineHiddenKinds.contains(kind) },
              set: { hide in
                var current = draft.timelineHiddenKinds
                if hide {
                  current.insert(kind)
                } else {
                  current.remove(kind)
                }
                draft.timelineHiddenKinds = current
              }
            )
          )
        }
      }
    } header: {
      Text("Timeline")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Toggle which GitHub event types appear in the dependency \
        PR conversation feed. Stepper bounds: 10–100 in 10-step \
        increments — `Picker(10…100)` would mount 91 rows on \
        Settings open.
        """
      )
    }
  }

  private func kindDisplayName(_ kind: DependencyUpdateTimelineKind) -> String {
    switch kind {
    case .issueComment: return "Comments"
    case .review: return "Reviews"
    case .reviewThread: return "Review threads"
    case .commit: return "Commits"
    case .headRefForcePushed: return "Force pushes"
    case .headRefDeleted: return "Head branch deleted"
    case .headRefRestored: return "Head branch restored"
    case .baseRefChanged: return "Base branch changed"
    case .baseRefForcePushed: return "Base branch force-pushed"
    case .baseRefDeleted: return "Base branch deleted"
    case .labeled: return "Label added"
    case .unlabeled: return "Label removed"
    case .assigned: return "Assigned"
    case .unassigned: return "Unassigned"
    case .merged: return "Merged"
    case .closed: return "Closed"
    case .reopened: return "Reopened"
    case .renamedTitle: return "Renamed title"
    case .reviewRequested: return "Review requested"
    case .reviewRequestRemoved: return "Review request removed"
    case .reviewDismissed: return "Review dismissed"
    case .readyForReview: return "Ready for review"
    case .convertToDraft: return "Converted to draft"
    case .autoMergeEnabled: return "Auto-merge enabled"
    case .autoMergeDisabled: return "Auto-merge disabled"
    case .autoRebaseEnabled: return "Auto-rebase enabled"
    case .autoSquashEnabled: return "Auto-squash enabled"
    case .locked: return "Locked"
    case .unlocked: return "Unlocked"
    case .pinned: return "Pinned"
    case .unpinned: return "Unpinned"
    case .milestoned: return "Milestoned"
    case .demilestoned: return "Demilestoned"
    case .referenced: return "Referenced"
    case .crossReferenced: return "Cross-referenced"
    case .mentioned: return "Mentioned"
    case .subscribed: return "Subscribed"
    case .unsubscribed: return "Unsubscribed"
    case .markedAsDuplicate: return "Marked as duplicate"
    case .unmarkedAsDuplicate: return "Unmarked as duplicate"
    case .transferred: return "Transferred"
    case .connected: return "Linked"
    case .disconnected: return "Unlinked"
    case .revisionMarker: return "Revision marker"
    case .unknown: return "Unknown event"
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
          HarnessMonitorAccessibility.settingsDependenciesPerRepoIntervalField
      )
      Picker("Max Concurrent Fetches", selection: $draft.maxConcurrentRepositoryFetches) {
        ForEach(Self.maxConcurrentRange, id: \.self) { count in
          Text(verbatim: "\(count)").tag(count)
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsDependenciesMaxConcurrentField
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

  static let minimumDurationSeconds: UInt64 = 30
  static let refreshPresetsSeconds: [UInt64] = [30, 60, 120, 300, 600, 900, 1_800, 3_600]
  static let cachePresetsSeconds: [UInt64] = [60, 300, 600, 900, 1_800, 3_600, 7_200, 21_600]
  static let maxConcurrentRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardDependenciesPreferences.minimumConcurrentRepositoryFetches,
      upper: DashboardDependenciesPreferences.maximumConcurrentRepositoryFetches
    )
  )
  static let timelinePageSizeRange: ClosedRange<Int> = ClosedRange(
    uncheckedBounds: (
      lower: DashboardDependenciesPreferences.minimumTimelinePageSize,
      upper: DashboardDependenciesPreferences.maximumTimelinePageSize
    )
  )
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
