import SwiftUI

public struct WindowSurfaceContext: Equatable, Sendable {
  public let windowID: String
  public let isKeyWindow: Bool
  public let navigationScope: WindowNavigationScope?
  public let openWindow: @MainActor @Sendable (String) -> Void
  private let openMainWindowAction: (@MainActor @Sendable () -> Void)?

  public init(
    windowID: String = "",
    isKeyWindow: Bool = true,
    navigationScope: WindowNavigationScope? = nil,
    openWindow: @escaping @MainActor @Sendable (String) -> Void = { _ in },
    openMainWindow: (@MainActor @Sendable () -> Void)? = nil
  ) {
    self.windowID = windowID
    self.isKeyWindow = isKeyWindow
    self.navigationScope = navigationScope
    self.openWindow = openWindow
    openMainWindowAction = openMainWindow
  }

  @MainActor
  public func openMainWindow() {
    if let openMainWindowAction {
      openMainWindowAction()
    } else {
      openWindow(HarnessMonitorWindowID.dashboard)
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.windowID == rhs.windowID
      && lhs.isKeyWindow == rhs.isKeyWindow
      && lhs.navigationScope == rhs.navigationScope
  }
}

public struct OpenTaskBoardSettingsAction: Sendable {
  private let action: @MainActor @Sendable (SettingsTaskBoardAnchor) -> Void

  public init(
    _ action: @escaping @MainActor @Sendable (SettingsTaskBoardAnchor) -> Void = { _ in }
  ) {
    self.action = action
  }

  @MainActor
  public func callAsFunction(_ anchor: SettingsTaskBoardAnchor = .githubProject) {
    action(anchor)
  }
}

public struct OpenSettingsSectionAction: Sendable {
  private let action: @MainActor @Sendable (SettingsSection) -> Void

  public init(
    _ action: @escaping @MainActor @Sendable (SettingsSection) -> Void = { _ in }
  ) {
    self.action = action
  }

  @MainActor
  public func callAsFunction(_ section: SettingsSection) {
    action(section)
  }
}

public struct OpenDashboardRouteAction: Sendable, Equatable {
  private let identity: ObjectIdentifier?
  private let action: @MainActor @Sendable (DashboardWindowRoute) -> Void

  public init(
    identity: ObjectIdentifier? = nil,
    _ action: @escaping @MainActor @Sendable (DashboardWindowRoute) -> Void = { _ in }
  ) {
    self.identity = identity
    self.action = action
  }

  @MainActor
  public func callAsFunction(_ route: DashboardWindowRoute) {
    action(route)
  }

  /// The dashboard host rebuilds this action on every body pass, so callers tag
  /// it with the stable navigation-history identity. SwiftUI then sees an
  /// unchanged environment value and skips re-evaluating
  /// `@Environment(\.openDashboardRoute)` readers (the Debugging route) on each
  /// column toggle. Identity-less actions stay distinct, preserving the prior
  /// always-changed behavior for callers that do not opt in.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard let lhs = lhs.identity, let rhs = rhs.identity else { return false }
    return lhs == rhs
  }
}

/// Initial filter applied when opening the Supervisor audit timeline via a
/// cross-link. The host wires this through to whatever filter store the
/// audit-timeline pane uses; passing `nil` for a field means "no constraint".
public struct SupervisorAuditTimelineQuery: Equatable, Hashable, Sendable {
  public let ruleID: String?
  public let decisionID: String?

  public init(ruleID: String? = nil, decisionID: String? = nil) {
    self.ruleID = ruleID
    self.decisionID = decisionID
  }
}

public struct OpenSupervisorAuditTimelineAction: Sendable {
  private let action: @MainActor @Sendable (SupervisorAuditTimelineQuery) -> Void

  public init(
    _ action: @escaping @MainActor @Sendable (SupervisorAuditTimelineQuery) -> Void = { _ in }
  ) {
    self.action = action
  }

  @MainActor
  public func callAsFunction(
    _ query: SupervisorAuditTimelineQuery = SupervisorAuditTimelineQuery()
  ) {
    action(query)
  }
}

private struct OpenTaskBoardSettingsActionKey: EnvironmentKey {
  static let defaultValue = OpenTaskBoardSettingsAction()
}

private struct OpenSettingsSectionActionKey: EnvironmentKey {
  static let defaultValue = OpenSettingsSectionAction()
}

private struct OpenDashboardRouteActionKey: EnvironmentKey {
  static let defaultValue = OpenDashboardRouteAction()
}

private struct OpenSupervisorAuditTimelineActionKey: EnvironmentKey {
  static let defaultValue = OpenSupervisorAuditTimelineAction()
}

private struct WindowSurfaceContextKey: EnvironmentKey {
  static let defaultValue = WindowSurfaceContext()
}

extension EnvironmentValues {
  public var openTaskBoardSettings: OpenTaskBoardSettingsAction {
    get { self[OpenTaskBoardSettingsActionKey.self] }
    set { self[OpenTaskBoardSettingsActionKey.self] = newValue }
  }

  public var openSettingsSection: OpenSettingsSectionAction {
    get { self[OpenSettingsSectionActionKey.self] }
    set { self[OpenSettingsSectionActionKey.self] = newValue }
  }

  public var openDashboardRoute: OpenDashboardRouteAction {
    get { self[OpenDashboardRouteActionKey.self] }
    set { self[OpenDashboardRouteActionKey.self] = newValue }
  }

  public var openSupervisorAuditTimeline: OpenSupervisorAuditTimelineAction {
    get { self[OpenSupervisorAuditTimelineActionKey.self] }
    set { self[OpenSupervisorAuditTimelineActionKey.self] = newValue }
  }

  public var windowSurfaceContext: WindowSurfaceContext {
    get { self[WindowSurfaceContextKey.self] }
    set { self[WindowSurfaceContextKey.self] = newValue }
  }
}
