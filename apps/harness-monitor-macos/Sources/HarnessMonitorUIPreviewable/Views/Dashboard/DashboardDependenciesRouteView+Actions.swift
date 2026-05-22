import HarnessMonitorKit
import SwiftUI

extension DashboardDependenciesRouteView {
  func reload(forceRefresh: Bool, backgroundRefresh: Bool = false) async {
    hydrateDependenciesFromCacheIfNeeded()
    guard store.apiClient != nil else {
      switch dashboardDependenciesMissingClientState(
        backgroundRefresh: backgroundRefresh,
        connectionState: store.connectionState
      ) {
      case .ignore:
        return
      case .loading:
        routeIsLoading = true
        routeErrorMessage = nil
        return
      case .error(let message):
        routeIsLoading = false
        routeErrorMessage = message
        return
      }
    }
    if backgroundRefresh {
      routeIsBackgroundRefreshing = true
    } else {
      routeIsLoading = true
      routeErrorMessage = nil
    }
    defer {
      if backgroundRefresh {
        routeIsBackgroundRefreshing = false
      } else {
        routeIsLoading = false
      }
    }
    await startScheduler(forceRefreshAll: forceRefresh)
  }

  func clearCacheAndReload() async {
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

  func approve(items: [DependencyUpdateItem]) async {
    await performMutation("Approving", items: items) { client in
      try await client.approveDependencyUpdates(
        request: DependencyUpdatesApproveRequest(targets: items.map(\.target))
      )
    }
  }

  func merge(items: [DependencyUpdateItem]) async {
    let nextID = nextSelectionID(after: items)
    await performMutation(
      "Merging",
      items: items,
      onSuccess: {
        if let nextID {
          routeSelectedIDs = [nextID]
        }
      },
      operation: { client in
        try await client.mergeDependencyUpdates(
          request: DependencyUpdatesMergeRequest(
            targets: items.map(\.target),
            method: normalizedPreferences.mergeMethod
          )
        )
      }
    )
  }

  func nextSelectionID(after items: [DependencyUpdateItem]) -> String? {
    let mergedIDs = Set(items.map(\.pullRequestID))
    let list = filteredItems
    guard
      let lastMergedIndex = list.lastIndex(where: { mergedIDs.contains($0.pullRequestID) })
    else {
      return nil
    }
    return list[(lastMergedIndex + 1)...]
      .first(where: { !mergedIDs.contains($0.pullRequestID) })?
      .pullRequestID
  }

  func rerunChecks(items: [DependencyUpdateItem]) async {
    await performMutation("Rerunning", items: items) { client in
      try await client.rerunDependencyUpdateChecks(
        request: DependencyUpdatesRerunChecksRequest(targets: items.map(\.rerunTarget))
      )
    }
  }

  func rerunCheck(_ check: DependencyUpdateCheck, for item: DependencyUpdateItem) async {
    guard check.isRerunnable, let checkSuiteID = check.checkSuiteID else {
      store.toast.presentWarning(
        check.rerunUnavailableReason ?? "This check cannot be rerun from the dashboard"
      )
      return
    }
    let target = DependencyUpdateTarget(
      pullRequestID: item.pullRequestID,
      repositoryID: item.repositoryID,
      repository: item.repository,
      number: item.number,
      url: item.url,
      headSha: item.headSha,
      mergeable: item.mergeable,
      reviewStatus: item.reviewStatus,
      checkStatus: item.checkStatus,
      policyBlocked: item.policyBlocked,
      checkSuiteIDs: [checkSuiteID]
    )
    await performMutation("Rerunning \(check.name)", items: [item]) { client in
      try await client.rerunDependencyUpdateChecks(
        request: DependencyUpdatesRerunChecksRequest(targets: [target])
      )
    }
  }

  func refresh(items: [DependencyUpdateItem]) {
    guard let client = store.apiClient, !items.isEmpty else { return }
    scheduleAffectedRefresh(for: items, using: client)
  }

  func addLabel(_ label: String, to items: [DependencyUpdateItem]) async {
    await performMutation(
      "Labeling",
      items: items,
      onSuccess: { recordLabelUsage(label, items: items) },
      operation: { client in
        try await client.addDependencyUpdateLabel(
          request: DependencyUpdatesLabelRequest(targets: items.map(\.target), label: label)
        )
      }
    )
  }

  func auto(items: [DependencyUpdateItem]) async {
    await performMutation("Running auto mode", items: items) { client in
      try await client.autoDependencyUpdates(
        request: DependencyUpdatesAutoRequest(
          targets: items.map(\.target),
          method: normalizedPreferences.mergeMethod
        )
      )
    }
  }

  func rebaseViaBot(item: DependencyUpdateItem, bot: DependencyUpdateBot) async {
    await performMutation(bot.rebaseActionTitle, items: [item]) { client in
      try await client.commentDependencyUpdates(
        request: DependencyUpdatesCommentRequest(
          targets: [item.target],
          body: bot.rebaseCommentBody
        )
      )
    }
  }

  func fixCI(item: DependencyUpdateItem) async {
    guard let client = store.apiClient else { return }
    routeInFlightActionTitle = "Creating Fix CI work…"
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
    routeInFlightActionTitle = nil
  }

  func performMutation(
    _ title: String,
    items: [DependencyUpdateItem],
    onSuccess: @MainActor () -> Void = {},
    operation:
      @escaping (any HarnessMonitorClientProtocol) async throws
      -> DependencyUpdatesActionResponse
  ) async {
    guard let client = store.apiClient else { return }
    let trackedIDs = items.map(\.pullRequestID)
    beginRefreshing(pullRequestIDs: trackedIDs, actionTitle: title)
    routeInFlightActionTitle = title
    defer {
      routeInFlightActionTitle = nil
      endRefreshing(pullRequestIDs: trackedIDs)
    }
    do {
      let response = try await operation(client)
      store.presentSuccessFeedback(response.summary)
      onSuccess()
      scheduleAffectedRefresh(for: items, using: client)
    } catch {
      store.presentFailureFeedback(error.localizedDescription)
    }
  }

  func openItem(_ item: DependencyUpdateItem) {
    guard let url = URL(string: item.url) else { return }
    openURL(url)
  }

  func copyApprovalLinks(for items: [DependencyUpdateItem]) {
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

  func relativeUpdatedLabel(for item: DependencyUpdateItem) -> String {
    relativeUpdatedLabels[item.pullRequestID] ?? item.updatedAt
  }

  func toggleRepositoryCollapse(_ repository: String) {
    var collapsed = routeCollapsedRepositories
    collapsed.toggle(repository)
    routeCollapsedRepositories = collapsed
    routeCollapsedRepositoriesStorage = collapsed.encodedString
  }

  func reconcileSelection() {
    let liveIDs = Set(routeResponse.items.map(\.pullRequestID))
    routeSelectedIDs = routeSelectedIDs.intersection(liveIDs)
    if routeSelectedIDs.isEmpty, let persisted = persistedPrimarySelectionID.nonEmpty,
      liveIDs.contains(persisted)
    {
      routeSelectedIDs = [persisted]
    }
  }

  @MainActor
  func rebuildPresentation(input: DashboardDependenciesPresentationInput) async {
    routePresentationGeneration &+= 1
    let generation = routePresentationGeneration
    let presentation = await routePresentationWorker.compute(input: input)
    guard !Task.isCancelled, routePresentationGeneration == generation else {
      return
    }
    if routeCachedPresentation != presentation {
      routeCachedPresentation = presentation
    }
  }
}
