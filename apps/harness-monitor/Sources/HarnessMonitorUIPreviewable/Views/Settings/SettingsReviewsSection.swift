import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsSection: View {
  private static let kindDisplayNames: [ReviewTimelineKind: String] = [
    .issueComment: "Comments",
    .review: "Reviews",
    .reviewThread: "Review threads",
    .commit: "Commits",
    .headRefForcePushed: "Force pushes",
    .headRefDeleted: "Head branch deleted",
    .headRefRestored: "Head branch restored",
    .baseRefChanged: "Base branch changed",
    .baseRefForcePushed: "Base branch force-pushed",
    .baseRefDeleted: "Base branch deleted",
    .labeled: "Label added",
    .unlabeled: "Label removed",
    .assigned: "Assigned",
    .unassigned: "Unassigned",
    .merged: "Merged",
    .closed: "Closed",
    .reopened: "Reopened",
    .renamedTitle: "Renamed title",
    .reviewRequested: "Review requested",
    .reviewRequestRemoved: "Review request removed",
    .reviewDismissed: "Review dismissed",
    .readyForReview: "Ready for review",
    .convertToDraft: "Converted to draft",
    .autoMergeEnabled: "Auto-merge enabled",
    .autoMergeDisabled: "Auto-merge disabled",
    .autoRebaseEnabled: "Auto-rebase enabled",
    .autoSquashEnabled: "Auto-squash enabled",
    .locked: "Locked",
    .unlocked: "Unlocked",
    .pinned: "Pinned",
    .unpinned: "Unpinned",
    .milestoned: "Milestoned",
    .demilestoned: "Demilestoned",
    .referenced: "Referenced",
    .crossReferenced: "Cross-referenced",
    .mentioned: "Mentioned",
    .subscribed: "Subscribed",
    .unsubscribed: "Unsubscribed",
    .markedAsDuplicate: "Marked as duplicate",
    .unmarkedAsDuplicate: "Unmarked as duplicate",
    .transferred: "Transferred",
    .connected: "Linked",
    .disconnected: "Unlinked",
    .revisionMarker: "Revision marker",
    .unknown: "Unknown event",
  ]

  @Binding var navigationRequest: SettingsNavigationRequest?
  @AppStorage(DashboardReviewsPreferences.storageKey)
  private var storedPreferences = ""
  @State private var draft = DashboardReviewsPreferences()
  @State private var hasLoadedDraft = false
  @State private var hiddenKindsSearchText = ""
  // Pre-filter via `.onChange(of: hiddenKindsSearchText)` rather than
  // computing `.filter(...)` inline in ForEach: filtering O(45) every
  // body call burns work that the debounce + cached @State path avoids.
  // ForEach(filteredHiddenKinds, id: \.rawValue) keeps toggle identity
  // stable as the list grows/shrinks with the search query.
  @State private var filteredHiddenKinds: [ReviewTimelineKind] =
    ReviewTimelineKind.allCases
  @State private var hiddenKindsSearchTask: Task<Void, Never>?

  init(navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)) {
    _navigationRequest = navigationRequest
  }

  var body: some View {
    Form {
      sourceScopeSection
      behaviorSection
      displaySection
      refreshSection
      Section {
        SettingsReviewsFilesSection(draft: $draft)
      } header: {
        Text("Files").harnessNativeFormSectionHeader()
      }
      timelineSection
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsRoot)
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

  private var displaySection: some View {
    Section {
      Toggle("Show avatars in review rows", isOn: $draft.showAvatarsInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowAvatarsToggle
        )
      Toggle("Show labels in review rows", isOn: $draft.showLabelsInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowLabelsToggle
        )
      Toggle(
        "Show +/- line counters in review rows",
        isOn: $draft.showLineCountersInRows
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsShowRowLineCountersToggle
      )
      Toggle("Show PR numbers in review rows", isOn: $draft.showPullRequestNumberInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowPullRequestNumberToggle
        )
      Toggle("Show PR age in review rows", isOn: $draft.showPullRequestAgeInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsShowRowPullRequestAgeToggle
        )
      Toggle("Wrap PR titles in review rows", isOn: $draft.wrapTitlesInRows)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsReviewsWrapRowTitlesToggle
        )
      Stepper(
        "Wrapped title max lines: \(draft.rowTitleMaximumLines)",
        value: $draft.rowTitleMaximumLines,
        in: Self.rowTitleMaximumLinesRange
      )
      .disabled(!draft.wrapTitlesInRows)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsRowTitleMaximumLinesField
      )
      Toggle(
        "Hide semantic commit prefixes in review row titles",
        isOn: $draft.hideSemanticPrefixesInRowTitles
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsHideSemanticPrefixesInRowTitlesToggle
      )
    } header: {
      Text("Display")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        These controls change the compact Reviews list only. Wrapped titles use the max-line limit above, while hover help and pull request detail keep the full original title.
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
        TextField("Search", text: $hiddenKindsSearchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Search hidden event types")
        if filteredHiddenKinds.isEmpty {
          ContentUnavailableView.search(text: hiddenKindsSearchText)
        } else {
          ForEach(filteredHiddenKinds, id: \.rawValue) { kind in
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
      }
      .onChange(of: hiddenKindsSearchText) { _, query in
        hiddenKindsSearchTask?.cancel()
        hiddenKindsSearchTask = Task { @MainActor in
          // 200ms debounce keeps the O(45) filter off the per-keystroke
          // body path. Cancellation propagates if the user keeps typing.
          try? await Task.sleep(for: .milliseconds(200))
          guard !Task.isCancelled else { return }
          let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty {
            filteredHiddenKinds = ReviewTimelineKind.allCases
          } else {
            filteredHiddenKinds = ReviewTimelineKind.allCases.filter { kind in
              kindDisplayName(kind).localizedCaseInsensitiveContains(trimmed)
            }
          }
        }
      }
    } header: {
      Text("Timeline")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Toggle which GitHub event types appear in the review \
        PR conversation feed. Stepper bounds: 10–100 in 10-step \
        increments — `Picker(10…100)` would mount 91 rows on \
        Settings open.
        """
      )
    }
  }

  private func kindDisplayName(_ kind: ReviewTimelineKind) -> String {
    Self.kindDisplayNames[kind] ?? "Unknown event"
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

  static let minimumDurationSeconds: UInt64 = 30
  static let refreshPresetsSeconds: [UInt64] = [30, 60, 120, 300, 600, 900, 1_800, 3_600]
  static let cachePresetsSeconds: [UInt64] = [60, 300, 600, 900, 1_800, 3_600, 7_200, 21_600]
  static let maxConcurrentRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumConcurrentRepositoryFetches,
      upper: DashboardReviewsPreferences.maximumConcurrentRepositoryFetches
    )
  )
  static let timelinePageSizeRange: ClosedRange<Int> = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumTimelinePageSize,
      upper: DashboardReviewsPreferences.maximumTimelinePageSize
    )
  )
  static let frequentLabelsCountRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumFrequentLabelsCount,
      upper: DashboardReviewsPreferences.maximumFrequentLabelsCount
    )
  )
  static let rowTitleMaximumLinesRange = ClosedRange(
    uncheckedBounds: (
      lower: DashboardReviewsPreferences.minimumRowTitleMaximumLines,
      upper: DashboardReviewsPreferences.maximumRowTitleMaximumLines
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
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsReviewsReloadButton
            ) {
              reloadDraft()
            }
            HarnessMonitorActionButton(
              title: "Save",
              tint: nil,
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsReviewsSaveButton
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
    draft = DashboardReviewsPreferences.decode(from: storedPreferences).normalized()
    hasLoadedDraft = true
  }

  private func saveDraft() {
    let normalized = draft.normalized()
    draft = normalized
    storedPreferences = normalized.encodedString
  }
}
