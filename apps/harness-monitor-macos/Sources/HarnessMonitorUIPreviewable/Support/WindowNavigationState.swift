import Observation
import SwiftUI

@MainActor
public struct WindowNavigationState {
  public let canGoBack: Bool
  public let canGoForward: Bool

  private let handlers: WindowNavigationHandlers

  public init(
    canGoBack: Bool = false,
    canGoForward: Bool = false
  ) {
    self.init(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      handlers: WindowNavigationHandlers()
    )
  }

  private init(
    canGoBack: Bool,
    canGoForward: Bool,
    handlers: WindowNavigationHandlers
  ) {
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.handlers = handlers
  }

  public func updating(
    canGoBack: Bool,
    canGoForward: Bool
  ) -> Self {
    Self(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      handlers: handlers
    )
  }

  public func setHandlers(
    back: (@MainActor () async -> Void)?,
    forward: (@MainActor () async -> Void)?
  ) {
    handlers.backHandler = back
    handlers.forwardHandler = forward
  }

  public func navigateBack() async {
    await handlers.backHandler?()
  }

  public func navigateForward() async {
    await handlers.forwardHandler?()
  }
}

public enum WindowNavigationScope: Hashable {
    case main
    case agents

    public static var agentTui: Self { .agents }
}

@MainActor
private final class WindowNavigationHandlers {
  var backHandler: (@MainActor () async -> Void)?
  var forwardHandler: (@MainActor () async -> Void)?
}

@MainActor
@Observable
public final class WindowCommandRoutingState {
  public var activeScope: WindowNavigationScope?
  private var activeWindowID: ObjectIdentifier?

  public init(activeScope: WindowNavigationScope? = nil) {
    self.activeScope = activeScope
  }

  public func activate(scope: WindowNavigationScope?, windowID: ObjectIdentifier) {
    guard activeScope != scope || activeWindowID != windowID else {
      return
    }
    activeScope = scope
    activeWindowID = windowID
  }

  public func clear(windowID: ObjectIdentifier) {
    guard activeWindowID == windowID else {
      return
    }
    activeScope = nil
    activeWindowID = nil
  }
}

@MainActor
@Observable
public final class AgentsWindowNavigationBridge {
  public var state = WindowNavigationState()

  public init() {}

  public func update(_ state: WindowNavigationState) {
    self.state = state
  }

  public func navigateBack() async {
    await state.navigateBack()
  }

  public func navigateForward() async {
    await state.navigateForward()
  }
}

public typealias AgentTuiWindowNavigationBridge = AgentsWindowNavigationBridge
