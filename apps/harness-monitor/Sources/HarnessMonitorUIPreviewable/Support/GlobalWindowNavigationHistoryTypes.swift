import HarnessMonitorKit
import SwiftUI

@MainActor
enum GlobalWindowNavigationEntry: Hashable {
  case dashboard(selection: DashboardWindowSelection)
  case session(sessionID: String, selection: SessionSelection)
}

enum DashboardWindowSelection: Hashable, Sendable {
  case route(DashboardWindowRoute)
  case agents(DashboardAgentIdentity)
  case reviews(DashboardReviewsHistorySelection)

  var route: DashboardWindowRoute {
    switch self {
    case .route(let route):
      route
    case .agents:
      .agents
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

  var agentIdentity: DashboardAgentIdentity? {
    guard case .agents(let identity) = self else { return nil }
    return identity
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

struct DashboardAgentsNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let identity: DashboardAgentIdentity
}

struct SessionWindowNavigationRestoreRequest: Equatable, Sendable {
  let requestID: Int
  let sessionID: String
  let selection: SessionSelection
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
