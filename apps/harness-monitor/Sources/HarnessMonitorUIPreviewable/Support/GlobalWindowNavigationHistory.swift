import AppKit
import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
enum GlobalWindowNavigationEntry: Hashable {
  case dashboard(selection: DashboardWindowSelection)
  case session(sessionID: String, selection: SessionSelection)
}

enum DashboardWindowSelection: Hashable, Sendable {
  case route(DashboardWindowRoute)
  case reviews(DashboardReviewsHistorySelection)

  var route: DashboardWindowRoute {
    switch self {
    case .route(let route):
      route
    case .reviews:
      .reviews
    }
  }

  var reviewsSelection: DashboardReviewsHistorySelection? {
    guard case .reviews(let selection) = self else {
      return nil
    }
    return selection
  }
}

struct DashboardWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let selection: DashboardWindowSelection

  var route: DashboardWindowRoute { selection.route }
}

struct DashboardReviewsNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let selection: DashboardReviewsHistorySelection
}

struct SessionWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let sessionID: String
  let selection: SessionSelection
}

@MainActor
@Observable
public final class GlobalWindowNavigationHistory {
  private(set) var backStack: [GlobalWindowNavigationEntry] = []
  private(set) var forwardStack: [GlobalWindowNavigationEntry] = []
  private(set) var currentEntry: GlobalWindowNavigationEntry?
  private(set) var dashboardSelection: DashboardWindowSelection = .route(.taskBoard)
  private(set) var latestSessionSelections: [String: SessionSelection] = [:]
  private(set) var pendingDashboardRestoreRequest: DashboardWindowNavigationRestoreRequest?
  private(set) var pendingDashboardReviewsRestoreRequest: DashboardReviewsNavigationRestoreRequest?
  private(set) var pendingSessionRestoreRequest: SessionWindowNavigationRestoreRequest?

  @ObservationIgnored private let store: HarnessMonitorStore
  @ObservationIgnored private var navigator: (@MainActor (GlobalWindowNavigationEntry) -> Void)?
  @ObservationIgnored private var restoreRequestSequence = 0

  public init(store: HarnessMonitorStore) {
    self.store = store
    currentEntry = .dashboard(selection: dashboardSelection)
  }

  var canGoBack: Bool {
    backStack.contains(where: canRestore)
  }

  var canGoForward: Bool {
    forwardStack.contains(where: canRestore)
  }

  func installNavigator(openWindow: OpenWindowAction) {
    GlobalWindowNavigationHistoryRegistry.current = self
    navigator = { entry in
      if self.activateExistingWindowIfPossible(for: entry) {
        return
      }
      switch entry {
      case .dashboard:
        openWindow.openHarnessDashboardWindow(
          mergeIfNeeded: true,
          recordHistory: false
        )
      case .session(let sessionID, _):
        openWindow.openHarnessSessionWindow(
          sessionID: sessionID,
          mergeIfNeeded: true,
          recordHistory: false
        )
      }
    }
  }

  func installDashboardStateIfNeeded(route: DashboardWindowRoute) {
    dashboardSelection = .route(route)
    guard currentEntry == nil else {
      return
    }
    currentEntry = .dashboard(selection: .route(route))
  }

  func installSessionStateIfNeeded(
    sessionID: String,
    selection: SessionSelection
  ) {
    latestSessionSelections[sessionID] = selection
    guard currentEntry == nil else {
      return
    }
    currentEntry = .session(sessionID: sessionID, selection: selection)
  }

  func recordDashboardRoute(_ route: DashboardWindowRoute) {
    guard pendingDashboardRestoreRequest?.route != route else {
      return
    }
    recordDashboardSelection(.route(route))
  }

  func recordDashboardSelection(_ selection: DashboardWindowSelection) {
    dashboardSelection = selection
    if pendingDashboardRestoreRequest?.selection == selection {
      return
    }
    if let reviewsSelection = selection.reviewsSelection,
      pendingDashboardReviewsRestoreRequest?.selection == reviewsSelection
    {
      return
    }
    if shouldUpgradeCurrentDashboardEntry(to: selection) {
      currentEntry = .dashboard(selection: selection)
      return
    }
    record(.dashboard(selection: selection))
  }

  func recordSessionSelection(
    sessionID: String,
    selection: SessionSelection
  ) {
    latestSessionSelections[sessionID] = selection
    if let pendingSessionRestoreRequest,
      pendingSessionRestoreRequest.sessionID == sessionID,
      pendingSessionRestoreRequest.selection == selection
    {
      return
    }
    record(.session(sessionID: sessionID, selection: selection))
  }

  func recordDashboardOpen() {
    record(.dashboard(selection: dashboardSelection))
  }

  public func requestDashboardRoute(_ route: DashboardWindowRoute) {
    restoreRequestSequence += 1
    dashboardSelection = .route(route)
    pendingSessionRestoreRequest = nil
    pendingDashboardReviewsRestoreRequest = nil
    pendingDashboardRestoreRequest = DashboardWindowNavigationRestoreRequest(
      requestID: restoreRequestSequence,
      selection: .route(route)
    )
    navigator?(.dashboard(selection: .route(route)))
  }

  func recordSessionOpen(sessionID: String) {
    let selection = latestSessionSelections[sessionID] ?? .route(.overview)
    latestSessionSelections[sessionID] = selection
    record(.session(sessionID: sessionID, selection: selection))
  }

  func navigateBack() {
    guard let destination = nextRestorableEntry(from: &backStack) else {
      return
    }
    if let currentEntry {
      forwardStack.append(currentEntry)
    }
    currentEntry = destination
    restore(destination)
  }

  func navigateForward() {
    guard let destination = nextRestorableEntry(from: &forwardStack) else {
      return
    }
    if let currentEntry {
      backStack.append(currentEntry)
    }
    currentEntry = destination
    restore(destination)
  }

  func finishDashboardRestoreRequest(_ requestID: Int) {
    guard pendingDashboardRestoreRequest?.requestID == requestID else {
      return
    }
    pendingDashboardRestoreRequest = nil
  }

  func finishDashboardReviewsRestoreRequest(_ requestID: Int) {
    guard pendingDashboardReviewsRestoreRequest?.requestID == requestID else {
      return
    }
    pendingDashboardReviewsRestoreRequest = nil
  }

  func finishSessionRestoreRequest(
    _ requestID: Int,
    sessionID: String
  ) {
    guard let pendingRequest = pendingSessionRestoreRequest else {
      return
    }
    guard
      pendingRequest.requestID == requestID
        && pendingRequest.sessionID == sessionID
    else {
      return
    }
    pendingSessionRestoreRequest = nil
  }

  private func record(_ entry: GlobalWindowNavigationEntry) {
    guard currentEntry != entry else {
      return
    }
    if let currentEntry {
      backStack.append(currentEntry)
    }
    currentEntry = entry
    if !forwardStack.isEmpty {
      forwardStack.removeAll()
    }
  }

  private func restore(_ entry: GlobalWindowNavigationEntry) {
    restoreRequestSequence += 1

    switch entry {
    case .dashboard(let selection):
      dashboardSelection = selection
      pendingSessionRestoreRequest = nil
      pendingDashboardRestoreRequest = DashboardWindowNavigationRestoreRequest(
        requestID: restoreRequestSequence,
        selection: selection
      )
      if case .reviews(let reviewsSelection) = selection {
        pendingDashboardReviewsRestoreRequest = DashboardReviewsNavigationRestoreRequest(
          requestID: restoreRequestSequence,
          selection: reviewsSelection
        )
      } else {
        pendingDashboardReviewsRestoreRequest = nil
      }
    case .session(let sessionID, let selection):
      latestSessionSelections[sessionID] = selection
      pendingDashboardRestoreRequest = nil
      pendingDashboardReviewsRestoreRequest = nil
      pendingSessionRestoreRequest = SessionWindowNavigationRestoreRequest(
        requestID: restoreRequestSequence,
        sessionID: sessionID,
        selection: selection
      )
    }

    navigator?(entry)
  }

  private func activateExistingWindowIfPossible(
    for entry: GlobalWindowNavigationEntry
  ) -> Bool {
    let expectedIdentifier =
      switch entry {
      case .dashboard:
        HarnessMonitorWindowID.dashboard
      case .session(let sessionID, _):
        HarnessMonitorWindowID.sessionWindow(sessionID)
      }

    guard
      let window = NSApplication.shared.windows.first(where: {
        $0.identifier?.rawValue == expectedIdentifier
          && !$0.isMiniaturized
          && $0.canBecomeKey
      })
    else {
      return false
    }

    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if let group = window.tabGroup, group.selectedWindow !== window {
      group.selectedWindow = window
    }
    window.makeKeyAndOrderFront(nil)
    return true
  }

  private func nextRestorableEntry(
    from stack: inout [GlobalWindowNavigationEntry]
  ) -> GlobalWindowNavigationEntry? {
    while let candidate = stack.popLast() {
      if canRestore(candidate) {
        return candidate
      }
    }
    return nil
  }

  private func canRestore(_ entry: GlobalWindowNavigationEntry) -> Bool {
    switch entry {
    case .dashboard:
      true
    case .session(let sessionID, _):
      store.openSessionWindowIDsSnapshot.contains(sessionID)
        || store.sessionIndex.sessionSummary(for: sessionID) != nil
    }
  }

  private func shouldUpgradeCurrentDashboardEntry(
    to selection: DashboardWindowSelection
  ) -> Bool {
    guard pendingDashboardReviewsRestoreRequest == nil else {
      return false
    }
    guard let currentEntry else {
      return false
    }
    guard case .dashboard(selection: .route(.reviews)) = currentEntry else {
      return false
    }
    return selection.route == .reviews
  }
}

@MainActor
public enum GlobalWindowNavigationHistoryRegistry {
  public static var current: GlobalWindowNavigationHistory?
}

private struct GlobalWindowNavigationHistoryKey: @preconcurrency EnvironmentKey {
  @MainActor static let defaultValue: GlobalWindowNavigationHistory? = nil
}

extension EnvironmentValues {
  public var globalWindowNavigationHistory: GlobalWindowNavigationHistory? {
    get { self[GlobalWindowNavigationHistoryKey.self] }
    set { self[GlobalWindowNavigationHistoryKey.self] = newValue }
  }
}
