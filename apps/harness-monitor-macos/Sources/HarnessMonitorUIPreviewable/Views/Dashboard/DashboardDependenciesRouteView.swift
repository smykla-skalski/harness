// swiftlint:disable file_length
// swiftlint:disable type_body_length
import HarnessMonitorKit
import SwiftUI

@MainActor private let dependenciesTimestampFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateStyle = .medium
  formatter.timeStyle = .short
  return formatter
}()

@MainActor private let dependenciesRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

@MainActor private let dependenciesISO8601Formatter = ISO8601DateFormatter()

struct DashboardDependenciesReloadTaskKey: Equatable {
  let storedPreferences: String
  let refreshToken: Int
  let connectionState: HarnessMonitorStore.ConnectionState
}

enum DashboardDependenciesMissingClientState: Equatable {
  case ignore
  case loading
  case error(String)
}

func dashboardDependenciesMissingClientState(
  backgroundRefresh: Bool,
  connectionState: HarnessMonitorStore.ConnectionState
) -> DashboardDependenciesMissingClientState {
  guard !backgroundRefresh else {
    return .ignore
  }
  if connectionState == .connecting {
    return .loading
  }
  return .error("The dependencies route needs a daemon client")
}

@MainActor
struct DashboardDependenciesRouteView: View {
  let store: HarnessMonitorStore
  @Binding var selectedRoute: DashboardWindowRoute

  @Environment(\.openSettingsSection)
  private var openSettingsSection
  @Environment(\.openURL)
  private var openURL

  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedPreferences = ""
  @SceneStorage("dashboard.dependencies.filter")
  private var filterModeRaw = DashboardDependenciesFilterMode.all.rawValue
  @SceneStorage("dashboard.dependencies.sort")
  private var sortModeRaw = DashboardDependenciesSortMode.status.rawValue
  @SceneStorage("dashboard.dependencies.group")
  private var groupModeRaw = DashboardDependenciesGroupMode.repository.rawValue
  @SceneStorage("dashboard.dependencies.search")
  private var searchText = ""
  @SceneStorage("dashboard.dependencies.primary-selection")
  private var persistedPrimarySelectionID = ""
  @SceneStorage("dashboard.dependencies.collapsed-repositories")
  private var collapsedRepositoriesStorage = ""
  @SceneStorage("dashboard.dependencies.content-detail-width")
  private var contentDetailWidth = SessionContentDetailSplitLayout.defaultContentWidth

  @State var response = DependencyUpdatesQueryResponse(
    fetchedAt: "",
    fromCache: false,
    summary: DependencyUpdatesSummary(
      total: 0,
      reviewRequired: 0,
      readyToMerge: 0,
      autoApprovable: 0,
      waitingOnChecks: 0,
      blocked: 0
    ),
    items: []
  )
  @State private var isLoading = false
  @State private var isBackgroundRefreshing = false
  @State private var errorMessage: String?
  @State private var selectedIDs = Set<String>()
  @State private var refreshToken = 0
  @State private var isLabelSheetPresented = false
  @State private var labelDraft = ""
  @State private var labelTargetItems = [DependencyUpdateItem]()
  @State private var inFlightActionTitle: String?
  @State private var presentationWorker = DashboardDependenciesPresentationWorker()
  @State private var cachedPresentation = DashboardDependenciesPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State var refreshingPullRequestIDs = Set<String>()

  private var preferences: DashboardDependenciesPreferences {
    get { DashboardDependenciesPreferences.decode(from: storedPreferences) }
    nonmutating set { storedPreferences = newValue.encodedString }
  }

  private var reloadTaskKey: DashboardDependenciesReloadTaskKey {
    DashboardDependenciesReloadTaskKey(
      storedPreferences: storedPreferences,
      refreshToken: refreshToken,
      connectionState: store.connectionState
    )
  }

  var normalizedPreferences: DashboardDependenciesPreferences {
    preferences.normalized()
  }

  private var collapsedRepositories: DashboardDependenciesCollapsedRepositories {
    get { DashboardDependenciesCollapsedRepositories.decode(from: collapsedRepositoriesStorage) }
    nonmutating set { collapsedRepositoriesStorage = newValue.encodedString }
  }

  private var groupMode: DashboardDependenciesGroupMode {
    DashboardDependenciesGroupMode(rawValue: groupModeRaw) ?? .repository
  }

  private var presentationInput: DashboardDependenciesPresentationInput {
    let preferences = normalizedPreferences
    return DashboardDependenciesPresentationInput(
      items: response.items,
      filterModeRaw: filterModeRaw,
      sortModeRaw: sortModeRaw,
      searchText: searchText,
      configuredRepositories: preferences.normalizedRepositories,
      configuredOrganizations: preferences.normalizedOrganizations,
      selectedIDs: selectedIDs,
      persistedPrimarySelectionID: persistedPrimarySelectionID
    )
  }

  private var filteredItems: [DependencyUpdateItem] {
    cachedPresentation.filteredItems
  }

  private var groupedItems: [DashboardDependenciesRepositoryGroup] {
    cachedPresentation.groupedItems
  }

  private var selectedItems: [DependencyUpdateItem] {
    cachedPresentation.selectedItems
  }

  private var primaryDetailItem: DependencyUpdateItem? {
    cachedPresentation.primaryDetailItem
  }

  private var summarySubtitle: String {
    guard let fetchedAt = parsedDate(response.fetchedAt) else {
      return response.fromCache ? "Showing cached results" : "Dependencies from configured sources"
    }
    let timestamp = dependenciesTimestampFormatter.string(from: fetchedAt)
    let relative = dependenciesRelativeFormatter.localizedString(for: fetchedAt, relativeTo: .now)
    return response.fromCache
      ? "Cached at \(timestamp) (\(relative))"
      : "Last refreshed \(timestamp) (\(relative))"
  }

  var body: some View {
    SessionContentDetailSplitView(
      contentWidth: $contentDetailWidth,
      commitContentWidth: { contentDetailWidth = $0 },
      dividerAccessibilityIdentifier:
        HarnessMonitorAccessibility.dashboardDependenciesDetailDivider,
      content: { contentPane },
      detail: { detailPane }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRoot)
    .task(id: reloadTaskKey) {
      await reload(forceRefresh: false)
    }
    .task(id: storedPreferences) {
      await runAutoRefreshLoop()
    }
    .task(id: presentationInput) {
      await rebuildPresentation(input: presentationInput)
    }
    .sheet(isPresented: $isLabelSheetPresented) {
      labelSheet
    }
    .onChange(of: selectedIDs) { _, newValue in
      persistedPrimarySelectionID = newValue.min() ?? persistedPrimarySelectionID
    }
  }

  private var contentPane: some View {
    VStack(alignment: .leading, spacing: 16) {
      summaryCard
      filterBar
      contentListPane
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(24)
  }

  @ViewBuilder private var contentListPane: some View {
    if let errorMessage, !isLoading {
      errorState(message: errorMessage)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      dependenciesList
    }
  }

  private var summaryCard: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        Image(systemName: DashboardWindowRoute.dependencies.systemImage)
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.accent)
          .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Dependencies")
            .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
          Text(summarySubtitle)
            .scaledFont(.callout)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        if let inFlightActionTitle {
          ProgressView(inFlightActionTitle)
            .controlSize(.small)
        } else if isBackgroundRefreshing {
          ProgressView("Refreshing…")
            .controlSize(.small)
        }
      }

      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        summaryBadge("\(response.summary.total) total", tint: HarnessMonitorTheme.accent)
        summaryBadge("\(response.summary.readyToMerge) ready", tint: HarnessMonitorTheme.success)
        summaryBadge(
          "\(response.summary.reviewRequired) review",
          tint: HarnessMonitorTheme.secondaryInk
        )
        summaryBadge(
          "\(response.summary.waitingOnChecks) waiting",
          tint: HarnessMonitorTheme.caution
        )
        summaryBadge("\(response.summary.blocked) blocked", tint: HarnessMonitorTheme.danger)
        if response.fromCache {
          summaryBadge("cached", tint: HarnessMonitorTheme.secondaryInk)
        }
        summaryBadge(
          "refresh \(normalizedPreferences.refreshIntervalDescription)",
          tint: HarnessMonitorTheme.secondaryInk
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(SessionTimelineCardBackground(tint: HarnessMonitorTheme.accent))
  }

  private var filterBar: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TextField("Search repos, titles, authors, or labels", text: $searchText)
        .textFieldStyle(.roundedBorder)

      filterControls
      routeActions
    }
  }

  private var filterControls: some View {
    DashboardDependenciesControlStrip(
      filterModeRaw: $filterModeRaw,
      sortModeRaw: $sortModeRaw,
      groupModeRaw: $groupModeRaw
    )
  }

  private var routeActions: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        routeActionButtons
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var routeActionButtons: some View {
    actionButton("Refresh", systemImage: "arrow.clockwise") {
      refreshToken += 1
      Task { await reload(forceRefresh: true) }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesRefreshButton)

    actionButton("Configure Sources", systemImage: "line.3.horizontal.decrease.circle") {
      openSettingsSection(.repositories)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesConfigureButton)

    actionButton("Secrets", systemImage: "key") {
      openSettingsSection(.secrets)
    }

    actionButton("Clear Cache", systemImage: "trash") {
      Task { await clearCacheAndReload() }
    }
  }

  private var dependenciesList: some View {
    List(selection: $selectedIDs) {
      if filteredItems.isEmpty, !isLoading {
        ContentUnavailableView {
          Label("No dependency updates", systemImage: "shippingbox")
        } description: {
          Text("Adjust your filters or configure a broader source scope")
        }
        .frame(maxWidth: .infinity, minHeight: 280)
      } else if groupMode == .repository {
        ForEach(groupedItems, id: \.repository) { group in
          Section {
            if !collapsedRepositories.contains(group.repository) {
              ForEach(group.items) { item in
                dependencyRow(item, showsRepository: false)
              }
            }
          } header: {
            repositorySectionHeader(group.repository, itemCount: group.items.count)
          }
        }
      } else {
        ForEach(filteredItems) { item in
          dependencyRow(item, showsRepository: true)
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesList)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overlay {
      if isLoading {
        ProgressView("Loading dependencies…")
          .controlSize(.large)
      }
    }
  }

  private var detailPane: some View {
    Group {
      if let errorMessage, !isLoading {
        errorState(message: errorMessage)
      } else if selectedItems.count > 1 {
        batchDetail
      } else if let item = primaryDetailItem {
        dependencyDetail(item)
      } else if isLoading {
        ProgressView("Loading dependencies…")
      } else {
        ContentUnavailableView {
          Label("Select a dependency update", systemImage: "sidebar.right")
        } description: {
          Text("Review checks, approvals, labels, and native actions without leaving the dashboard")
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesDetail)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var batchDetail: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        detailCard(
          title: "\(selectedItems.count) selected",
          subtitle: "Run batch dependency actions across the current selection"
        ) {
          dependencyActionBar(items: selectedItems)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func dependencyDetail(_ item: DependencyUpdateItem) -> some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        detailCard(
          title: item.title, subtitle: "\(item.repository)#\(item.number) · @\(item.authorLogin)"
        ) {
          dependencyActionBar(items: [item])
        }
        detailMetrics(for: item)
        detailSection("Checks") {
          if item.checks.isEmpty {
            Text("No checks reported")
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          } else {
            ForEach(item.checks) { check in
              HStack(alignment: .firstTextBaseline) {
                Text(check.name)
                Spacer()
                Text(check.statusLabel)
                  .foregroundStyle(check.tint)
              }
              .scaledFont(.callout)
            }
          }
        }
        detailSection("Reviews") {
          if item.reviews.isEmpty {
            Text("No reviews yet")
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          } else {
            ForEach(item.reviews) { review in
              HStack(alignment: .firstTextBaseline) {
                Text(review.author)
                Spacer()
                Text(review.state.label)
                  .foregroundStyle(review.state.tint)
              }
              .scaledFont(.callout)
            }
          }
        }
        detailSection("Labels") {
          if item.labels.isEmpty {
            Text("No labels applied")
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          } else {
            HarnessMonitorWrapLayout(
              spacing: HarnessMonitorTheme.spacingSM,
              lineSpacing: HarnessMonitorTheme.spacingSM
            ) {
              ForEach(item.labels, id: \.self) { label in
                summaryBadge(label, tint: HarnessMonitorTheme.secondaryInk)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func dependencyRow(
    _ item: DependencyUpdateItem,
    showsRepository: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(item.title)
          .fontWeight(.semibold)
          .lineLimit(2)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(verbatim: "#\(item.number)")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        if showsRepository {
          Text(item.repository)
          Text("·")
        }
        Text(item.statusLabel)
        if refreshingPullRequestIDs.contains(item.pullRequestID) {
          ProgressView()
            .controlSize(.mini)
            .accessibilityLabel("Refreshing pull request")
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(item.relativeUpdatedLabel)
      }
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .tag(item.pullRequestID)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    .contextMenu {
      Button("Open Pull Request") {
        openItem(item)
      }
      Button("Copy Link") {
        HarnessMonitorClipboard.copy(item.url)
      }
      Divider()
      Button("Approve") {
        Task { await approve(items: [item]) }
      }
      .disabled(!item.canAttemptManualApproval)
      Button("Merge") {
        Task { await merge(items: [item]) }
      }
      .disabled(!item.canAttemptManualMerge)
      Button("Rerun Checks") {
        Task { await rerunChecks(items: [item]) }
      }
      .disabled(!item.hasRerunnableChecks)
      DashboardDependenciesLabelPickerMenu(
        title: "Add Label",
        labels: dashboardDependenciesAvailableLabels(
          repositoryLabels: response.repositoryLabels,
          items: [item]
        ),
        onSelect: { name in Task { await addLabel(name, to: [item]) } },
        onCustom: {
          labelTargetItems = [item]
          labelDraft = ""
          isLabelSheetPresented = true
        }
      )
      Button("Auto") {
        Task { await auto(items: [item]) }
      }
      .disabled(!item.canRunAutoMode)
      if item.canStartFixCI {
        Button("Fix CI") {
          Task { await fixCI(item: item) }
        }
      }
    }
  }

  private func repositorySectionHeader(_ repository: String, itemCount: Int) -> some View {
    let isCollapsed = collapsedRepositories.contains(repository)
    return Button {
      toggleRepositoryCollapse(repository)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 12, alignment: .center)
        Text(repository)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Text(verbatim: String(itemCount))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }

  private func detailMetrics(for item: DependencyUpdateItem) -> some View {
    detailSection("Status") {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        summaryBadge(item.statusLabel, tint: item.statusTint)
        summaryBadge(item.reviewStatus.label, tint: item.reviewStatus.tint)
        summaryBadge(
          "\(item.additions)+ / \(item.deletions)-", tint: HarnessMonitorTheme.secondaryInk)
        if item.policyBlocked {
          summaryBadge("policy wait", tint: HarnessMonitorTheme.caution)
        }
      }
    }
  }

  private func dependencyActionBar(items: [DependencyUpdateItem]) -> some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        dependencyActionButtons(items: items)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func dependencyActionButtons(items: [DependencyUpdateItem]) -> some View {
    actionButton("Approve", systemImage: "checkmark.seal") {
      Task { await approve(items: items) }
    }
    .disabled(!items.contains { $0.canAttemptManualApproval })

    actionButton("Merge", systemImage: "arrow.triangle.merge") {
      Task { await merge(items: items) }
    }
    .disabled(!items.contains { $0.canAttemptManualMerge })

    actionButton("Rerun Checks", systemImage: "arrow.clockwise.circle") {
      Task { await rerunChecks(items: items) }
    }
    .disabled(!items.contains { $0.hasRerunnableChecks })

    DashboardDependenciesLabelPickerActionMenu(
      labels: dashboardDependenciesAvailableLabels(
        repositoryLabels: response.repositoryLabels,
        items: items
      ),
      onSelect: { name in Task { await addLabel(name, to: items) } },
      onCustom: {
        labelTargetItems = items
        labelDraft = ""
        isLabelSheetPresented = true
      }
    )
    .disabled(items.isEmpty)

    actionButton("Copy Approval Links", systemImage: "doc.on.doc") {
      copyApprovalLinks(for: items)
    }

    if items.count == 1, let item = items.first {
      actionButton("Auto", systemImage: "bolt") {
        Task { await auto(items: [item]) }
      }
      .disabled(!item.canRunAutoMode)
      actionButton("Open Pull Request", systemImage: "safari") {
        openItem(item)
      }
      if item.canStartFixCI {
        actionButton("Fix CI", systemImage: "wrench.and.screwdriver") {
          Task { await fixCI(item: item) }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesFixCIButton)
      }
    } else {
      actionButton("Auto", systemImage: "bolt") {
        Task { await auto(items: items) }
      }
      .disabled(!items.contains { $0.canRunAutoMode })
    }
  }

  private var labelSheet: some View {
    DashboardDependenciesCustomLabelSheet(
      items: labelTargetItems,
      suggestions: dashboardDependenciesAvailableLabels(
        repositoryLabels: response.repositoryLabels,
        items: labelTargetItems
      ),
      draft: $labelDraft,
      onApply: { label in
        isLabelSheetPresented = false
        let items = labelTargetItems
        labelTargetItems = []
        Task { await addLabel(label, to: items) }
      },
      onCancel: {
        labelTargetItems = []
        isLabelSheetPresented = false
      }
    )
  }

  private func detailCard<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
      Text(subtitle)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(SessionTimelineCardBackground(tint: HarnessMonitorTheme.accent))
  }

  private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.headline)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(SessionTimelineCardBackground(tint: HarnessMonitorTheme.secondaryInk))
  }

  private func summaryBadge(_ label: String, tint: Color) -> some View {
    SessionTimelineBadge(label: label, tint: tint, style: .quiet)
  }

  private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
  }

  private func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Dependencies unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Open Secrets") {
        openSettingsSection(.secrets)
      }
      Button("Open Sources Settings") {
        openSettingsSection(.repositories)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 320)
  }

  private func runAutoRefreshLoop() async {
    let refreshIntervalSeconds = normalizedPreferences.refreshIntervalSeconds
    guard refreshIntervalSeconds > 0 else {
      return
    }
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .seconds(refreshIntervalSeconds))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await reload(forceRefresh: true, backgroundRefresh: true)
    }
  }

  func reload(forceRefresh: Bool, backgroundRefresh: Bool = false) async {
    hydrateDependenciesFromCacheIfNeeded()
    guard let client = store.apiClient else {
      switch dashboardDependenciesMissingClientState(
        backgroundRefresh: backgroundRefresh,
        connectionState: store.connectionState
      ) {
      case .ignore:
        return
      case .loading:
        isLoading = true
        errorMessage = nil
        return
      case .error(let message):
        isLoading = false
        errorMessage = message
        return
      }
    }
    if backgroundRefresh {
      isBackgroundRefreshing = true
    } else {
      isLoading = true
      errorMessage = nil
    }
    defer {
      if backgroundRefresh {
        isBackgroundRefreshing = false
      } else {
        isLoading = false
      }
    }
    do {
      let loaded = try await client.queryDependencyUpdates(
        request: normalizedPreferences.queryRequest(forceRefresh: forceRefresh)
      )
      guard !Task.isCancelled else { return }
      response = loaded
      errorMessage = nil
      reconcileSelection()
      persistDependenciesResponse(loaded)
    } catch {
      guard !Task.isCancelled else { return }
      HarnessMonitorLogger.api.warning(
        "Dependency update reload failed: \(String(reflecting: error), privacy: .public)"
      )
      let displayMessage = dashboardDependenciesErrorMessage(for: error)
      if !response.items.isEmpty {
        store.presentFailureFeedback(displayMessage)
      } else {
        errorMessage = displayMessage
      }
    }
  }

  private func clearCacheAndReload() async {
    guard let client = store.apiClient else { return }
    do {
      let cleared = try await client.clearDependencyUpdatesCache()
      store.presentSuccessFeedback(
        "Cleared \(cleared.clearedEntries) cached dependency query bucket(s)"
      )
      await reload(forceRefresh: true)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  private func approve(items: [DependencyUpdateItem]) async {
    await performMutation("Approving", items: items) { client in
      try await client.approveDependencyUpdates(
        request: DependencyUpdatesApproveRequest(targets: items.map(\.target))
      )
    }
  }

  private func merge(items: [DependencyUpdateItem]) async {
    await performMutation("Merging", items: items) { client in
      try await client.mergeDependencyUpdates(
        request: DependencyUpdatesMergeRequest(
          targets: items.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
  }

  private func rerunChecks(items: [DependencyUpdateItem]) async {
    await performMutation("Rerunning", items: items) { client in
      try await client.rerunDependencyUpdateChecks(
        request: DependencyUpdatesRerunChecksRequest(targets: items.map(\.rerunTarget))
      )
    }
  }

  private func addLabel(_ label: String, to items: [DependencyUpdateItem]) async {
    await performMutation("Labeling", items: items) { client in
      try await client.addDependencyUpdateLabel(
        request: DependencyUpdatesLabelRequest(targets: items.map(\.target), label: label)
      )
    }
  }

  private func auto(items: [DependencyUpdateItem]) async {
    await performMutation("Running auto mode", items: items) { client in
      try await client.autoDependencyUpdates(
        request: DependencyUpdatesAutoRequest(
          targets: items.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
  }

  private func fixCI(item: DependencyUpdateItem) async {
    guard let client = store.apiClient else { return }
    inFlightActionTitle = "Creating Fix CI work…"
    do {
      _ = try await client.createTaskBoardItem(
        request: TaskBoardCreateItemRequest(
          title: "Fix CI · \(item.repository)#\(item.number)",
          body: """
            Investigate and restore mergeability for \(item.repository)#\(item.number).

            Pull request: \(item.url)
            Review status: \(item.reviewStatus.label)
            Check status: \(item.checkStatus.label)
            """,
          priority: item.requiresAttention ? .high : .medium,
          agentMode: .headless,
          tags: ["dependencies", "fix-ci"],
          externalRefs: [
            TaskBoardExternalRef(
              provider: .gitHub,
              externalId: "\(item.repository)#\(item.number)",
              url: item.url
            )
          ],
          planning: TaskBoardPlanningState(
            summary: "Repair dependency-update CI failures and restore mergeability"
          )
        )
      )
      selectedRoute = .taskBoard
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
    inFlightActionTitle = nil
  }

  private func performMutation(
    _ title: String,
    items: [DependencyUpdateItem],
    operation:
      @escaping (any HarnessMonitorClientProtocol) async throws
      -> DependencyUpdatesActionResponse
  ) async {
    guard let client = store.apiClient else { return }
    inFlightActionTitle = title
    defer { inFlightActionTitle = nil }
    do {
      let response = try await operation(client)
      store.presentSuccessFeedback(response.summary)
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  private func openItem(_ item: DependencyUpdateItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  private func copyApprovalLinks(for items: [DependencyUpdateItem]) {
    let scopedItems: [DependencyUpdateItem]
    if selectedItems.isEmpty, items.count == 1, let repository = items.first?.repository,
      groupMode == .repository
    {
      scopedItems = filteredItems.filter { $0.repository == repository }
    } else {
      scopedItems = items
    }
    let links =
      scopedItems
      .filter { $0.reviewStatus == .reviewRequired }
      .map(\.url)
    guard !links.isEmpty else {
      store.toast.presentWarning("No approval links are needed for the current scope")
      return
    }
    HarnessMonitorClipboard.copy(links.joined(separator: "\n"))
    store.presentSuccessFeedback("Copied \(links.count) approval link(s)")
  }

  private func toggleRepositoryCollapse(_ repository: String) {
    var collapsed = collapsedRepositories
    collapsed.toggle(repository)
    collapsedRepositories = collapsed
  }

  func reconcileSelection() {
    let liveIDs = Set(response.items.map(\.pullRequestID))
    selectedIDs = selectedIDs.intersection(liveIDs)
    if selectedIDs.isEmpty, let persisted = persistedPrimarySelectionID.nonEmpty,
      liveIDs.contains(persisted)
    {
      selectedIDs = [persisted]
    }
  }

  private func parsedDate(_ value: String) -> Date? {
    dependenciesISO8601Formatter.date(from: value)
  }

  @MainActor
  private func rebuildPresentation(input: DashboardDependenciesPresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let presentation = await presentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
  }
}

// swiftlint:enable type_body_length

private struct DashboardDependenciesControlStrip: View {
  @Binding var filterModeRaw: String
  @Binding var sortModeRaw: String
  @Binding var groupModeRaw: String

  var body: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      filterPicker
      sortPicker
      groupPicker
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var filterPicker: some View {
    Picker("Filter", selection: $filterModeRaw) {
      ForEach(DashboardDependenciesFilterMode.pickerCases) { mode in
        Text(mode.title).tag(mode.rawValue)
      }
    }
    .pickerStyle(.segmented)
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
}

struct DashboardDependenciesPreferences: Codable, Equatable {
  static let storageKey = "dashboard.dependencies.preferences"
  var authorsText = "renovate[bot]"
  var organizationsText = ""
  var repositoriesText = ""
  var excludeRepositoriesText = ""
  var mergeMethodRaw = TaskBoardGitHubMergeMethod.squash.rawValue
  var refreshIntervalSeconds: UInt64 = 300
  var cacheMaxAgeSeconds: UInt64 = 600

  var mergeMethod: TaskBoardGitHubMergeMethod {
    TaskBoardGitHubMergeMethod(rawValue: mergeMethodRaw)
  }

  var normalizedOrganizations: [String] {
    Self.normalizedEntries(organizationsText)
  }

  var normalizedRepositories: [String] {
    Self.normalizedEntries(repositoriesText)
  }

  var refreshIntervalDescription: String {
    if refreshIntervalSeconds.isMultiple(of: 60) {
      let minutes = refreshIntervalSeconds / 60
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }
    return "\(refreshIntervalSeconds)s"
  }

  var encodedString: String {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
  }

  func normalized() -> Self {
    var copy = self
    copy.authorsText = Self.normalizedText(authorsText)
    copy.organizationsText = Self.normalizedText(organizationsText)
    copy.repositoriesText = Self.normalizedText(repositoriesText)
    copy.excludeRepositoriesText = Self.normalizedText(excludeRepositoriesText)
    copy.refreshIntervalSeconds = max(refreshIntervalSeconds, 30)
    copy.cacheMaxAgeSeconds = max(cacheMaxAgeSeconds, 30)
    return copy
  }

  static func decode(from string: String) -> Self {
    guard
      let data = string.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self()
    }
    return decoded
  }

  func queryRequest(forceRefresh: Bool) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest(
      authors: Self.normalizedEntries(authorsText),
      organizations: Self.normalizedEntries(organizationsText),
      repositories: Self.normalizedEntries(repositoriesText),
      excludeRepositories: Self.normalizedEntries(excludeRepositoriesText),
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, 30)
    )
  }

  private static func normalizedText(_ text: String) -> String {
    normalizedEntries(text).joined(separator: ", ")
  }

  private static func normalizedEntries(_ text: String) -> [String] {
    text
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .removingDuplicates()
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
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
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
    guard
      let data = string.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self()
    }
    return decoded
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

private enum DashboardDependenciesGroupMode: String, CaseIterable, Identifiable {
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

extension DependencyUpdateItem {
  fileprivate var statusWeight: Int {
    switch true {
    case reviewStatus == .approved && checkStatus == .success:
      0
    case checkStatus == .pending:
      1
    case reviewStatus == .reviewRequired:
      2
    case checkStatus == .failure:
      3
    case mergeable == .conflicting:
      4
    default:
      5
    }
  }

  fileprivate var statusLabel: String {
    switch true {
    case isAutoMergeable: "Ready to merge"
    case isAutoApprovable: "Ready for approval"
    case checkStatus == .pending: "Checks running"
    case requiresAttention: "Needs attention"
    default: "Open"
    }
  }

  fileprivate var statusTint: Color {
    switch true {
    case isAutoMergeable: HarnessMonitorTheme.success
    case isAutoApprovable: HarnessMonitorTheme.accent
    case checkStatus == .pending: HarnessMonitorTheme.caution
    case requiresAttention: HarnessMonitorTheme.danger
    default: HarnessMonitorTheme.secondaryInk
    }
  }

  @MainActor fileprivate var relativeUpdatedLabel: String {
    guard
      let date = dependenciesISO8601Formatter.date(from: updatedAt)
    else {
      return updatedAt
    }
    return dependenciesRelativeFormatter.localizedString(for: date, relativeTo: .now)
  }
}

extension DependencyUpdateReviewStatus {
  fileprivate var label: String {
    switch self {
    case .approved: "Approved"
    case .reviewRequired: "Review required"
    case .changesRequested: "Changes requested"
    case .none, .unknown: "No review"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .reviewRequired: HarnessMonitorTheme.accent
    case .changesRequested: HarnessMonitorTheme.danger
    case .none, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckStatus {
  fileprivate var label: String {
    switch self {
    case .none: "No checks"
    case .success: "Checks passing"
    case .failure: "Checks failing"
    case .pending: "Checks pending"
    case .unknown(let raw): raw
    }
  }
}

extension DependencyUpdateCheck {
  fileprivate var statusLabel: String {
    switch status {
    case .completed: conclusion.label
    case .inProgress: "In progress"
    case .queued: "Queued"
    case .requested: "Requested"
    case .waiting: "Waiting"
    case .unknown: status.rawValue
    }
  }

  fileprivate var tint: Color {
    switch conclusion {
    case .success: HarnessMonitorTheme.success
    case .failure, .cancelled, .timedOut, .actionRequired, .startupFailure:
      HarnessMonitorTheme.danger
    case .none, .neutral, .skipped, .stale, .unknown:
      HarnessMonitorTheme.secondaryInk
    }
  }
}

extension DependencyUpdateCheckConclusion {
  fileprivate var label: String {
    switch self {
    case .success: "Success"
    case .failure: "Failure"
    case .neutral: "Neutral"
    case .cancelled: "Cancelled"
    case .timedOut: "Timed out"
    case .actionRequired: "Action required"
    case .skipped: "Skipped"
    case .stale: "Stale"
    case .startupFailure: "Startup failure"
    case .none, .unknown: "Unknown"
    }
  }
}

extension DependencyUpdateReviewEventState {
  fileprivate var label: String {
    switch self {
    case .approved: "Approved"
    case .changesRequested: "Changes requested"
    case .commented: "Commented"
    case .dismissed: "Dismissed"
    case .pending: "Pending"
    case .unknown: "Unknown"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .approved: HarnessMonitorTheme.success
    case .changesRequested: HarnessMonitorTheme.danger
    case .commented, .dismissed, .pending, .unknown: HarnessMonitorTheme.secondaryInk
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    isEmpty ? nil : self
  }
}

extension Array where Element == String {
  fileprivate func removingDuplicates() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
