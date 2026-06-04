import Foundation

extension DashboardReviewsRouteView {
  func applyPendingReviewSelectionIfNeeded() {
    guard let request = routeOpenAnythingReviews.selectionRequest else { return }
    // The selector may be a node-id `pullRequestID` (Open Anything) or a
    // deep-link slug ("owner/repo#number") from a `harness://` link. Resolve to
    // the loaded item so every downstream selection keys on the node id.
    guard
      let resolvedID = routeResponse.items
        .first(where: { $0.matchesDeepLinkSelector(request.pullRequestID) })?
        .pullRequestID
    else {
      return
    }
    // A deep link that names a file drives a deliberate jump through the
    // navigation history: it pushes one entry and arms the reviews restore
    // request, which switches into Files mode and applies the file + line
    // range. Without a history (previews/tests) fall back to PR-only selection.
    if let filePath = request.filePath, !filePath.isEmpty,
      let windowNavigationHistory
    {
      windowNavigationHistory.requestReviewsFileJump(
        DashboardReviewsHistorySelection(
          selectedPullRequestIDs: [resolvedID],
          primaryPullRequestID: resolvedID,
          detailMode: .files,
          selectedFilePath: filePath,
          lineSelection: request.lineSelection
        )
      )
      routeOpenAnythingReviews.finishSelection(requestID: request.requestID)
      return
    }
    routeSelectedIDs = [resolvedID]
    persistedPrimarySelectionID = resolvedID
    routeOpenAnythingReviews.finishSelection(requestID: request.requestID)
  }

  // Legacy filter values - `"blocked"` filter and `"dependencies"` category -
  // migrate once per session to the new toggle-based flags.
  func applyLegacyFilterMigrationIfNeeded() {
    guard !routeStateStorage.legacyFilterMigrationApplied else { return }
    routeStateStorage.legacyFilterMigrationApplied = true
    if filterModeRaw == "blocked" {
      needsMeOn = true
      filterModeRaw = DashboardReviewsFilterMode.all.rawValue
    }
    if categoryModeRaw == DashboardReviewsCategoryMode.dependencies.rawValue {
      dependenciesOnlyOn = true
      categoryModeRaw = DashboardReviewsCategoryMode.defaultMode.rawValue
    }
  }
}
