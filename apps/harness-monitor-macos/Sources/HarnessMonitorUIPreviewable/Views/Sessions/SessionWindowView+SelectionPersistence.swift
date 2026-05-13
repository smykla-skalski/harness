import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  func hydrateSelectionFromPersistedStorage() {
    guard case .route(.overview) = stateCache.selection else { return }
    if persistedRoute == .decisions {
      stateCache.selectRoute(.decisions)
      stateCache.setRouteDecisionID(persistedDecisionID.isEmpty ? nil : persistedDecisionID)
    } else if !persistedDecisionID.isEmpty {
      stateCache.selectDecision(persistedDecisionID)
    } else if persistedRoute != .overview {
      stateCache.selectRoute(persistedRoute)
    }
  }

  func hydrateDecisionFiltersFromPersistedStorage() {
    if stateCache.decisionFilters.query != persistedDecisionQuery {
      stateCache.decisionFilters.query = persistedDecisionQuery
    }
  }

  func syncPersistedStorage(from selection: SessionSelection) {
    let targetRoute: SessionWindowRoute
    let targetDecisionID: String
    switch selection {
    case .route(let route):
      targetRoute = route
      targetDecisionID = route == .decisions ? (stateCache.sectionState.decisionID ?? "") : ""
    case .agent:
      targetRoute = .agents
      targetDecisionID = ""
    case .codexRun:
      targetRoute = .agents
      targetDecisionID = ""
    case .decision(_, let decisionID):
      targetRoute = .decisions
      targetDecisionID = decisionID
    case .task:
      targetRoute = .tasks
      targetDecisionID = ""
    case .create:
      targetRoute = .agents
      targetDecisionID = ""
    }
    updatePersistedSelection(route: targetRoute, decisionID: targetDecisionID)
  }

  func clearPersistedDecisionQueryIfNeeded() {
    if !persistedDecisionQuery.isEmpty {
      persistedDecisionQuery = ""
    }
  }

  private func updatePersistedSelection(route: SessionWindowRoute, decisionID: String) {
    if persistedRoute != route {
      persistedRoute = route
    }
    if persistedDecisionID != decisionID {
      persistedDecisionID = decisionID
    }
  }
}
