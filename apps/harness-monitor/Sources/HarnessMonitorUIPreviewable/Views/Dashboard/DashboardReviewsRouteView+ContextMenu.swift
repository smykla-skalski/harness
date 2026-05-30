import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  @ViewBuilder
  func reviewSelectionContextMenu(for selection: Set<String>) -> some View {
    let items = contextMenuItems(forSelection: selection)
    if let primaryItem = items.first {
      let isSingleItem = items.count == 1
      let availableLabels = contextMenuAvailableLabels(for: items)
      let frequentNames = contextMenuFrequentNames(for: items)
      let isBusy = items.contains { isPullRequestRefreshing($0.pullRequestID) }
      let pinTitle = pinSelectionMenuTitle(for: items)
      // Right-clicking an unselected row leaves `routeSelectedIDs` stale: the
      // list-level `forSelectionType:` API hands us the row's tag for items
      // resolution, but the visible selection is unchanged. Sync it
      // asynchronously so the menu and any subsequent action operate on a
      // consistent set. State mutation can't run inline in a `@ViewBuilder`,
      // so defer it onto the next runloop tick. The `simultaneousGesture`
      // route is not viable on macOS 26 because right-clicks don't fire
      // `TapGesture`; priming at menu-open time is the smallest reliable
      // fallback.
      let _: Task<Void, Never> = Task { @MainActor in
        primeSelectionForContextMenu(items: items)
      }
      if isSingleItem {
        Button("Open Pull Request") {
          openItem(primaryItem)
        }
        Button("Copy Link") {
          HarnessMonitorClipboard.copy(primaryItem.url)
        }
      } else if items.count > 1 {
        Button(dashboardReviewsCopyLinksMenuTitle(itemCount: items.count)) {
          HarnessMonitorClipboard.copy(items.map(\.url).joined(separator: "\n"))
        }
      }
      Button(pinTitle) {
        togglePinnedSelection(items: items)
      }
      Divider()

      let areAllSnoozed = areAllItemsSnoozed(items)
      let areAnySnoozed = areAnyItemsSnoozed(items)

      if !areAllSnoozed {
        Menu("Snooze...") {
          Button("Until Tomorrow") {
            let tomorrow =
              Calendar.current.date(byAdding: .day, value: 1, to: .now)
              ?? .now.addingTimeInterval(86_400)
            snooze(items: items, condition: .untilDate(tomorrow))
          }
          Button("Until Next Week") {
            let nextWeek =
              Calendar.current.date(byAdding: .day, value: 7, to: .now)
              ?? .now.addingTimeInterval(7 * 86_400)
            snooze(items: items, condition: .untilDate(nextWeek))
          }
          Button("Until New Activity") {
            snooze(items: items, condition: .untilActivity(lastSeenUpdatedAt: ""))
          }
          Button("Indefinitely") {
            snooze(items: items, condition: .indefinitely)
          }
        }
      }

      if areAnySnoozed {
        Button("Unsnooze") {
          unsnooze(items: items)
        }
      }

      Divider()
      Button("Approve") {
        requestApproveOrConfirm(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canAttemptManualApproval })
      Button(dashboardReviewMergeActionTitle(for: items)) {
        requestMergeOrConfirm(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canAttemptManualMerge })
      Button("Rerun Checks") {
        Task { await rerunChecks(items: items) }
      }
      .disabled(isBusy || !items.contains { $0.canAttemptRerunChecks })
      Button("Refresh") {
        refresh(items: items)
      }
      .disabled(isBusy)
      DashboardReviewsLabelPickerMenu(
        title: "Add Label",
        labels: availableLabels,
        frequentNames: frequentNames,
        showsDescriptions: normalizedPreferences.showLabelDescriptions,
        onSelect: { name in Task { await addLabel(name, to: items) } },
        onCustom: {
          routeLabelTargetItems = items
          routeLabelDraft = ""
          routeIsLabelSheetPresented = true
        }
      )
      .disabled(isBusy || !items.contains { $0.canAddReviewLabel })
      Button("Auto") {
        requestAuto(items: items)
      }
      .disabled(isBusy || !items.contains { $0.canRunAutoMode })
      if isSingleItem, primaryItem.canStartFixCI {
        Button("Fix CI") {
          Task { await fixCI(item: primaryItem) }
        }
      }
    }
  }

  func contextMenuItems(forSelection selection: Set<String>) -> [ReviewItem] {
    guard !selection.isEmpty else { return [] }
    return filteredItems.filter { selection.contains($0.pullRequestID) }
  }

  func contextMenuAvailableLabels(
    for items: [ReviewItem]
  ) -> [ReviewRepositoryLabel] {
    if items.count == 1, let item = items.first {
      return rowAvailableLabels(for: item)
    }
    return dashboardReviewsAvailableLabels(
      repositoryLabels: routeResponse.repositoryLabels,
      items: items
    )
  }

  func contextMenuFrequentNames(for items: [ReviewItem]) -> [String] {
    if items.count == 1, let item = items.first {
      return rowFrequentLabelNames(for: item)
    }
    return frequentLabelNames(for: items)
  }

  /// Re-aligns the visible selection with the menu target when a right-click
  /// on an unselected row opens the context menu. List's
  /// `contextMenu(forSelectionType:)` resolves the closure's `selection`
  /// against the row under the cursor, but the visual selection and
  /// `routeSelectedIDs` do not change. This brings them in sync so action
  /// handlers and detail-pane bindings reflect the menu's scope.
  @discardableResult
  func primeSelectionForContextMenu(items: [ReviewItem]) -> Bool {
    var menuIDs = Set<String>()
    menuIDs.reserveCapacity(items.count)
    for item in items {
      menuIDs.insert(item.pullRequestID)
    }
    guard !menuIDs.isEmpty, menuIDs != routeSelectedIDs else { return false }
    routeSelectedIDs = menuIDs
    return true
  }

  private func areAllItemsSnoozed(_ items: [ReviewItem]) -> Bool {
    guard !items.isEmpty else { return false }
    let currentDate = Date.now
    return items.allSatisfy { item in
      routeSnoozedPullRequests.isSnoozed(
        item.pullRequestID, currentDate: currentDate, currentUpdatedAt: item.updatedAt)
    }
  }

  private func areAnyItemsSnoozed(_ items: [ReviewItem]) -> Bool {
    guard !items.isEmpty else { return false }
    let currentDate = Date.now
    return items.contains { item in
      routeSnoozedPullRequests.isSnoozed(
        item.pullRequestID, currentDate: currentDate, currentUpdatedAt: item.updatedAt)
    }
  }

  private func snooze(items: [ReviewItem], condition: DashboardReviewsSnoozeCondition) {
    var currentSnoozed = routeSnoozedPullRequests
    for item in items {
      let finalCondition: DashboardReviewsSnoozeCondition
      if case .untilActivity = condition {
        finalCondition = .untilActivity(lastSeenUpdatedAt: item.updatedAt)
      } else {
        finalCondition = condition
      }
      currentSnoozed.snooze(item.pullRequestID, condition: finalCondition)
    }
    routeSnoozedPullRequests = currentSnoozed
  }

  private func unsnooze(items: [ReviewItem]) {
    var currentSnoozed = routeSnoozedPullRequests
    for item in items {
      currentSnoozed.unsnooze(item.pullRequestID)
    }
    routeSnoozedPullRequests = currentSnoozed
  }
}

/// Returns the label for the multi-select "Copy N Links" context menu action.
/// Extracted as a pure helper so the title rule is unit-testable without
/// driving SwiftUI menu introspection.
public func dashboardReviewsCopyLinksMenuTitle(itemCount: Int) -> String {
  "Copy \(itemCount) Links"
}
