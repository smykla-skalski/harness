import AppKit
import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
enum GlobalWindowNavigationEntry: Hashable, Sendable {
  case dashboard(route: DashboardWindowRoute)
  case session(sessionID: String, selection: SessionSelection)
}

struct DashboardWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let route: DashboardWindowRoute

  init(
    requestID: Int,
    route: DashboardWindowRoute
  ) {
    self.requestID = requestID
    self.route = route
  }
}

struct SessionWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let sessionID: String
  let selection: SessionSelection

  init(
    requestID: Int,
    sessionID: String,
    selection: SessionSelection
  ) {
    self.requestID = requestID
    self.sessionID = sessionID
    self.selection = selection
  }
}

@MainActor
@Observable
public final class GlobalWindowNavigationHistory {
  private(set) var backStack: [GlobalWindowNavigationEntry] = []
  private(set) var forwardStack: [GlobalWindowNavigationEntry] = []
  private(set) var currentEntry: GlobalWindowNavigationEntry?
  private(set) var dashboardRoute: DashboardWindowRoute = .taskBoard
  private(set) var latestSessionSelections: [String: SessionSelection] = [:]
  private(set) var pendingDashboardRestoreRequest: DashboardWindowNavigationRestoreRequest?
  private(set) var pendingSessionRestoreRequest: SessionWindowNavigationRestoreRequest?

  @ObservationIgnored private let store: HarnessMonitorStore
  @ObservationIgnored private var navigator: (@MainActor (GlobalWindowNavigationEntry) -> Void)?
  @ObservationIgnored private var restoreRequestSequence = 0

  public init(store: HarnessMonitorStore) {
    self.store = store
    currentEntry = .dashboard(route: dashboardRoute)
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
    dashboardRoute = route
    guard currentEntry == nil else {
      return
    }
    currentEntry = .dashboard(route: route)
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
    dashboardRoute = route
    guard pendingDashboardRestoreRequest?.route != route else {
      return
    }
    record(.dashboard(route: route))
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
    record(.dashboard(route: dashboardRoute))
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
    case .dashboard(let route):
      dashboardRoute = route
      pendingSessionRestoreRequest = nil
      pendingDashboardRestoreRequest = DashboardWindowNavigationRestoreRequest(
        requestID: restoreRequestSequence,
        route: route
      )
    case .session(let sessionID, let selection):
      latestSessionSelections[sessionID] = selection
      pendingDashboardRestoreRequest = nil
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
    let expectedIdentifier = switch entry {
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
}

@MainActor
public enum GlobalWindowNavigationHistoryRegistry {
  public static var current: GlobalWindowNavigationHistory?
}
