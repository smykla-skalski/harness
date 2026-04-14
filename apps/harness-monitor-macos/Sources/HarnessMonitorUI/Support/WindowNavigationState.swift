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
  case agentTui
}

extension FocusedValues {
  @Entry public var windowNavigationScope: WindowNavigationScope?
}

@MainActor
private final class WindowNavigationHandlers {
  var backHandler: (@MainActor () async -> Void)?
  var forwardHandler: (@MainActor () async -> Void)?
}

@Observable
@MainActor
public final class AgentTuiWindowNavigationBridge {
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
