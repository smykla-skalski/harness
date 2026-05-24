import SwiftUI

extension DashboardReviewsRouteView {
  var currentDashboardHistorySelection: DashboardWindowSelection {
    .reviews(
      DashboardReviewsHistorySelection(
        selectedPullRequestIDs: Array(routeSelectedIDs),
        primaryPullRequestID: persistedPrimarySelectionID,
        detailMode: routeDetailMode
      )
    )
  }

  func recordCurrentHistorySelectionIfVisible() {
    guard selectedRoute == .reviews else {
      return
    }
    guard let windowNavigationHistory else {
      return
    }
    guard windowNavigationHistory.pendingDashboardReviewsRestoreRequest == nil else {
      return
    }
    windowNavigationHistory.recordDashboardSelection(currentDashboardHistorySelection)
  }

  /// Track a task so the pause-on-leave heuristic can reason about live work.
  ///
  /// The original implementation only appended; tasks that completed normally
  /// were never removed from the list, and `Task.isCancelled` is the wrong
  /// probe (it only flips on explicit cancellation, not on normal return).
  /// Under the new policy `hasActiveInFlightTasks` needs to reflect live work,
  /// so each tracked task pairs with a companion that awaits its completion
  /// and removes the handle from `routeInFlightTasks` once it has actually
  /// finished.
  func trackInFlight(_ task: Task<Void, Never>) {
    var tasks = routeInFlightTasks
    tasks.append(task)
    routeInFlightTasks = tasks
    Task { @MainActor in
      await task.value
      routeInFlightTasks.removeAll { $0 == task }
    }
  }

  func cancelAllInFlightTasks() {
    for task in routeInFlightTasks {
      task.cancel()
    }
    routeInFlightTasks = []
  }

  /// `true` when at least one tracked refresh or mutation task may still be
  /// running. Used to decide whether leaving the route should arm a
  /// "resume on return" reload.
  var hasActiveInFlightTasks: Bool {
    !routeInFlightTasks.isEmpty
  }

  /// React to the dashboard route picker switching to or from the reviews
  /// route. Leaving the route no longer cancels in-flight refreshes; the
  /// user expects pending work to keep going so that the next time they
  /// land on Reviews the data is already current. When work was in flight
  /// at the moment of departure we arm `pendingResumeAfterReturn` so a
  /// soft reload runs on return - the existing `task(id: reloadTaskKey)`
  /// only fires if the key changed, which is not enough for refreshes
  /// scheduled mid-view without a key change.
  func handleSelectedRouteChange(_ newValue: DashboardWindowRoute) {
    let decision = dashboardReviewsRouteChangeDecision(
      newRoute: newValue,
      wasOnReviews: routeIsReviewsRouteActive,
      hasInFlightWork: hasActiveInFlightTasks,
      hasPendingResume: routePendingResumeAfterReturn
    )
    switch decision {
    case .leave(let armPendingResume):
      routeIsReviewsRouteActive = false
      if armPendingResume {
        routePendingResumeAfterReturn = true
      }
    case .returnToRoute(let triggerReload):
      routeIsReviewsRouteActive = true
      if triggerReload {
        routePendingResumeAfterReturn = false
        Task { await reload(forceRefresh: false, backgroundRefresh: true) }
      }
    case .noChange:
      break
    }
  }

  @MainActor
  func applyPendingDashboardReviewsRestoreIfNeeded() async {
    guard selectedRoute == .reviews else {
      return
    }
    guard let windowNavigationHistory else {
      return
    }
    guard let request = windowNavigationHistory.pendingDashboardReviewsRestoreRequest else {
      return
    }
    guard request.requestID != routeHandledDashboardHistoryRestoreRequestID else {
      return
    }

    let selection = request.selection
    routeSelectedIDs = selection.selectedPullRequestIDSet
    persistedPrimarySelectionID = selection.primaryPullRequestID
    routeDetailMode = selection.detailMode

    if selection.detailMode == DashboardReviewsDetailMode.files {
      guard
        let item = routeResponse.items.first(where: {
          $0.pullRequestID == selection.primaryPullRequestID
        })
      else {
        return
      }
      routeHandledDashboardHistoryRestoreRequestID = request.requestID
      await prepareFilesMode(for: item)
    } else {
      routeHandledDashboardHistoryRestoreRequestID = request.requestID
    }

    await Task.yield()
    windowNavigationHistory.finishDashboardReviewsRestoreRequest(request.requestID)
  }
}
