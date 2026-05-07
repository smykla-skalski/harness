import SwiftUI

public struct SessionNavigationCommand: Equatable, @unchecked Sendable {
  public let sessionID: String
  public let canGoBack: Bool
  public let canGoForward: Bool
  public let goBack: () -> Void
  public let goForward: () -> Void

  public init(
    sessionID: String,
    canGoBack: Bool,
    canGoForward: Bool,
    goBack: @escaping () -> Void,
    goForward: @escaping () -> Void
  ) {
    self.sessionID = sessionID
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.goBack = goBack
    self.goForward = goForward
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionID == rhs.sessionID
      && lhs.canGoBack == rhs.canGoBack
      && lhs.canGoForward == rhs.canGoForward
  }
}

public struct SessionAttentionFocus: Equatable, Sendable {
  public let sessionID: String
  public let pendingDecisionCount: Int

  public init(sessionID: String, pendingDecisionCount: Int) {
    self.sessionID = sessionID
    self.pendingDecisionCount = pendingDecisionCount
  }
}

public struct SessionInspectorCommand: Equatable, @unchecked Sendable {
  public let sessionID: String
  public let isVisible: Bool
  public let toggle: () -> Void

  public init(sessionID: String, isVisible: Bool, toggle: @escaping () -> Void) {
    self.sessionID = sessionID
    self.isVisible = isVisible
    self.toggle = toggle
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionID == rhs.sessionID && lhs.isVisible == rhs.isVisible
  }
}

public struct SessionCreateContext: Equatable, @unchecked Sendable {
  public let sessionID: String
  public let primaryKind: SessionCreateKind
  public let createAgent: () -> Void
  public let createTask: () -> Void
  public let createDecision: () -> Void

  public init(
    sessionID: String,
    primaryKind: SessionCreateKind,
    createAgent: @escaping () -> Void,
    createTask: @escaping () -> Void,
    createDecision: @escaping () -> Void
  ) {
    self.sessionID = sessionID
    self.primaryKind = primaryKind
    self.createAgent = createAgent
    self.createTask = createTask
    self.createDecision = createDecision
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionID == rhs.sessionID && lhs.primaryKind == rhs.primaryKind
  }
}

public struct SessionDecisionCommand: Equatable, @unchecked Sendable {
  public let sessionID: String
  public let canDismissSelected: Bool
  public let canDismissVisible: Bool
  public let canReopenBatch: Bool
  public let dismissSelected: () -> Void
  public let dismissVisible: () -> Void
  public let reopenBatch: () -> Void

  public init(
    sessionID: String,
    canDismissSelected: Bool,
    canDismissVisible: Bool,
    canReopenBatch: Bool,
    dismissSelected: @escaping () -> Void,
    dismissVisible: @escaping () -> Void,
    reopenBatch: @escaping () -> Void
  ) {
    self.sessionID = sessionID
    self.canDismissSelected = canDismissSelected
    self.canDismissVisible = canDismissVisible
    self.canReopenBatch = canReopenBatch
    self.dismissSelected = dismissSelected
    self.dismissVisible = dismissVisible
    self.reopenBatch = reopenBatch
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionID == rhs.sessionID
      && lhs.canDismissSelected == rhs.canDismissSelected
      && lhs.canDismissVisible == rhs.canDismissVisible
      && lhs.canReopenBatch == rhs.canReopenBatch
  }
}

private struct SessionNavigationFocusKey: FocusedValueKey {
  typealias Value = SessionNavigationCommand
}

private struct SessionAttentionFocusKey: FocusedValueKey {
  typealias Value = SessionAttentionFocus
}

private struct SessionInspectorFocusKey: FocusedValueKey {
  typealias Value = SessionInspectorCommand
}

private struct SessionDecisionFocusKey: FocusedValueKey {
  typealias Value = SessionDecisionCommand
}

private struct SessionCreateContextFocusKey: FocusedValueKey {
  typealias Value = SessionCreateContext
}

extension FocusedValues {
  public var sessionNavigation: SessionNavigationCommand? {
    get { self[SessionNavigationFocusKey.self] }
    set { self[SessionNavigationFocusKey.self] = newValue }
  }

  public var sessionAttention: SessionAttentionFocus? {
    get { self[SessionAttentionFocusKey.self] }
    set { self[SessionAttentionFocusKey.self] = newValue }
  }

  public var sessionInspector: SessionInspectorCommand? {
    get { self[SessionInspectorFocusKey.self] }
    set { self[SessionInspectorFocusKey.self] = newValue }
  }

  public var sessionDecisionCommands: SessionDecisionCommand? {
    get { self[SessionDecisionFocusKey.self] }
    set { self[SessionDecisionFocusKey.self] = newValue }
  }

  public var sessionCreateContext: SessionCreateContext? {
    get { self[SessionCreateContextFocusKey.self] }
    set { self[SessionCreateContextFocusKey.self] = newValue }
  }
}

public enum SessionColumnVisibilityCodec {
  public static func encode(_ visibility: NavigationSplitViewVisibility) -> String {
    switch visibility {
    case .all: "all"
    case .doubleColumn: "doubleColumn"
    case .detailOnly: "detailOnly"
    case .automatic: "automatic"
    default: "automatic"
    }
  }

  public static func decode(_ raw: String) -> NavigationSplitViewVisibility {
    switch raw {
    case "all": .all
    case "doubleColumn": .doubleColumn
    case "detailOnly": .detailOnly
    case "automatic": .automatic
    default: .automatic
    }
  }
}
