import HarnessMonitorKit
import SwiftUI

struct DashboardDependenciesRepoLabelMenuData: Equatable, Sendable {
  let sortedLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
}

@MainActor
struct DashboardDependenciesRepositorySectionHeader: View {
  let repository: String
  let itemCount: Int
  let isCollapsed: Bool
  let scheduler: DashboardDependenciesScheduler
  let onToggleCollapse: () -> Void

  var body: some View {
    let isSyncing = scheduler.repositoriesInFlight.contains(repository)
    let lastSyncedAt = scheduler.states[repository]?.lastSyncedAt
    Button(action: onToggleCollapse) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 12, alignment: .center)
        Text(repository)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        if isSyncing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Syncing \(repository)")
        } else if let lastSyncedAt {
          let relative = dependenciesRelativeFormatter.localizedString(
            for: lastSyncedAt, relativeTo: .now)
          DashboardDependenciesRepositoryHeaderPill(
            title: relative,
            systemImage: "arrow.triangle.2.circlepath",
            accessibilityLabel: "Last synced \(relative)"
          )
        }
        DashboardDependenciesRepositoryHeaderPill(
          title: String(itemCount),
          accessibilityLabel: itemCountAccessibilityLabel
        )
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }

  private var itemCountAccessibilityLabel: String {
    itemCount == 1 ? "1 dependency update" : "\(itemCount) dependency updates"
  }
}

@MainActor
private struct DashboardDependenciesRepositoryHeaderPill: View {
  let title: String
  let systemImage: String?
  let accessibilityLabel: String

  @ScaledMetric(relativeTo: .caption)
  private var height = 22.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 8.0

  init(title: String, systemImage: String? = nil, accessibilityLabel: String) {
    self.title = title
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(verbatim: title)
        .monospacedDigit()
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, horizontalPadding)
    .frame(height: height, alignment: .center)
    .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
    .accessibilityLabel(accessibilityLabel)
  }
}

@MainActor
struct DashboardDependenciesDescriptionView: View {
  let store: HarnessMonitorStore
  let pullRequestID: String
  let viewerCanUpdate: Bool
  let onCheckboxError: ((String) -> Void)?
  let onCheckboxUpdated: (() -> Void)?

  init(
    store: HarnessMonitorStore,
    pullRequestID: String,
    viewerCanUpdate: Bool = true,
    onCheckboxError: ((String) -> Void)? = nil,
    onCheckboxUpdated: (() -> Void)? = nil
  ) {
    self.store = store
    self.pullRequestID = pullRequestID
    self.viewerCanUpdate = viewerCanUpdate
    self.onCheckboxError = onCheckboxError
    self.onCheckboxUpdated = onCheckboxUpdated
  }

  var body: some View {
    switch store.dependencyUpdateBodyState[pullRequestID] {
    case .loaded(let body):
      if body.isEmpty {
        Text("No description")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      } else if viewerCanUpdate {
        HarnessMonitorMarkdownText(body, textSelection: .enabled)
          .markdownCheckboxToggle { offset, newValue in
            toggleCheckbox(currentBody: body, offset: offset, newValue: newValue)
          }
      } else {
        HarnessMonitorMarkdownText(body, textSelection: .enabled)
      }
    case .failed(let message):
      Text(message)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .scaledFont(.callout)
    case .loading, nil:
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        ProgressView()
          .controlSize(.small)
        Text("Loading description…")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      }
    }
  }

  private func toggleCheckbox(currentBody: String, offset: Int, newValue: Bool) {
    var bytes = Array(currentBody.utf8)
    guard offset < bytes.count else { return }
    bytes[offset] = newValue ? 0x78 : 0x20
    guard let newBody = String(bytes: bytes, encoding: .utf8) else { return }
    Task { @MainActor in
      let outcome = await store.setDependencyUpdateBody(
        pullRequestID: pullRequestID,
        newBody: newBody,
        priorBody: currentBody
      )
      switch outcome {
      case .updated:
        onCheckboxUpdated?()
      case .bodyDrifted:
        onCheckboxError?("PR body changed since you opened it. Reloaded the latest version.")
      case .failed(let message):
        onCheckboxError?("Couldn't update PR body: \(message)")
      }
    }
  }
}

struct DashboardDependenciesControlStrip: View {
  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String
  let needsMeCount: Int
  let onRefresh: () -> Void
  let onClearCache: () -> Void

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.spacingSM,
          lineSpacing: HarnessMonitorTheme.spacingSM
        ) {
          needsMeChip
          filterPicker
          sortPicker
          groupPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        actionsMenu
          .fixedSize(horizontal: true, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var isNeedsMeActive: Bool {
    filterModeRaw == DashboardDependenciesFilterMode.blocked.rawValue
  }

  private var needsMeChip: some View {
    Toggle(isOn: needsMeBinding) {
      if needsMeCount > 0 {
        Text("Needs Me (\(needsMeCount))")
      } else {
        Text("Needs Me")
      }
    }
    .toggleStyle(.button)
    .controlSize(.regular)
    .accessibilityLabel("Filter to pull requests that need your attention")
  }

  private var needsMeBinding: Binding<Bool> {
    Binding(
      get: { isNeedsMeActive },
      set: { newValue in
        filterModeRaw =
          (newValue ? DashboardDependenciesFilterMode.blocked
            : DashboardDependenciesFilterMode.all).rawValue
      }
    )
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $filterModeRaw) {
      ForEach(DashboardDependenciesFilterMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesSelectionStatus)
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortModeRaw) {
      ForEach(DashboardDependenciesSortMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var groupPicker: some View {
    Picker("Group", selection: $groupModeRaw) {
      ForEach(DashboardDependenciesGroupMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }

  private var actionsMenu: some View {
    Menu {
      Button(action: onRefresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRefreshButton)

      Divider()

      Button(action: onClearCache) {
        Label("Clear Cache", systemImage: "trash")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .imageScale(.medium)
        .frame(width: 18, height: 18)
        .accessibilityLabel("More dependency actions")
    }
    .menuStyle(.button)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .accessibilityLabel("More dependency actions")
  }
}

struct DashboardDependenciesRepositoryOrdering {
  let configuredRepositories: [String]
  let configuredOrganizations: [String]

  func compare(_ lhs: String, _ rhs: String) -> Bool {
    sortKey(for: lhs) < sortKey(for: rhs)
  }

  func sorted(_ repositories: [String]) -> [String] {
    repositories.sorted(by: compare)
  }

  private func sortKey(for repository: String) -> DashboardDependenciesRepositorySortKey {
    if let index = configuredRepositories.firstIndex(of: repository) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 0,
        configuredIndex: index,
        organization: repositoryOwner(for: repository),
        repository: repository
      )
    }
    let organization = repositoryOwner(for: repository)
    if let index = configuredOrganizations.firstIndex(of: organization) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 1,
        configuredIndex: index,
        organization: organization,
        repository: repository
      )
    }
    return DashboardDependenciesRepositorySortKey(
      bucket: 2,
      configuredIndex: Int.max,
      organization: organization,
      repository: repository
    )
  }

  private func repositoryOwner(for repository: String) -> String {
    repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
  }
}

struct DashboardDependenciesCollapsedRepositories: Codable, Equatable {
  var repositories: [String] = []

  var encodedString: String {
    DashboardDependenciesStorageCodec.encodeToString(self)
  }

  func contains(_ repository: String) -> Bool {
    repositories.contains(repository)
  }

  mutating func toggle(_ repository: String) {
    if let index = repositories.firstIndex(of: repository) {
      repositories.remove(at: index)
    } else {
      repositories.append(repository)
      repositories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
  }

  static func decode(from string: String) -> Self {
    DashboardDependenciesStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}

private struct DashboardDependenciesRepositorySortKey: Comparable {
  let bucket: Int
  let configuredIndex: Int
  let organization: String
  let repository: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.bucket != rhs.bucket {
      return lhs.bucket < rhs.bucket
    }
    if lhs.configuredIndex != rhs.configuredIndex {
      return lhs.configuredIndex < rhs.configuredIndex
    }
    if lhs.organization != rhs.organization {
      return lhs.organization.localizedStandardCompare(rhs.organization) == .orderedAscending
    }
    return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
  }
}

enum DashboardDependenciesFilterMode: String, CaseIterable, Identifiable {
  case all
  case ready
  case review
  case waiting
  case blocked

  static let pickerCases: [Self] = [.all, .ready, .review, .waiting, .blocked]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .ready: "Ready"
    case .review: "Review"
    case .waiting: "Waiting"
    case .blocked: "Blocked"
    }
  }

  func matches(_ item: DependencyUpdateItem) -> Bool {
    switch self {
    case .all: true
    case .ready: item.isAutoMergeable
    case .review: item.reviewStatus == .reviewRequired
    case .waiting: item.checkStatus == .pending
    case .blocked: item.requiresAttention
    }
  }
}

enum DashboardDependenciesSortMode: String, CaseIterable, Identifiable {
  case status
  case age
  case repository

  static let pickerCases: [Self] = [.status, .age, .repository]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .status: "Status"
    case .age: "Age"
    case .repository: "Repository"
    }
  }

  var comparator: (DependencyUpdateItem, DependencyUpdateItem) -> Bool {
    switch self {
    case .status:
      { lhs, rhs in
        if lhs.statusWeight == rhs.statusWeight {
          return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
        }
        return lhs.statusWeight < rhs.statusWeight
      }
    case .age:
      { lhs, rhs in lhs.createdAt > rhs.createdAt }
    case .repository:
      { lhs, rhs in lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending }
    }
  }
}

enum DashboardDependenciesGroupMode: String, CaseIterable, Identifiable {
  case repository
  case flat

  static let pickerCases: [Self] = [.repository, .flat]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository: "By Repo"
    case .flat: "Flat"
    }
  }
}
