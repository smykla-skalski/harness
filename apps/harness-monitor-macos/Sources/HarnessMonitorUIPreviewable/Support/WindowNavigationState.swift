import Observation
import SwiftUI

public struct WindowNavigationState: Equatable {
  public let canGoBack: Bool
  public let canGoForward: Bool

  private let handlers: WindowNavigationHandlers

  @MainActor
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

  @MainActor
  private init(
    canGoBack: Bool,
    canGoForward: Bool,
    handlers: WindowNavigationHandlers
  ) {
    self.canGoBack = canGoBack
    self.canGoForward = canGoForward
    self.handlers = handlers
  }

  @MainActor
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

  @MainActor
  public func setHandlers(
    back: (@MainActor () -> Void)?,
    forward: (@MainActor () -> Void)?
  ) {
    handlers.backHandler = back
    handlers.forwardHandler = forward
  }

  @MainActor
  public func navigateBack() {
    handlers.backHandler?()
  }

  @MainActor
  public func navigateForward() {
    handlers.forwardHandler?()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canGoBack == rhs.canGoBack
      && lhs.canGoForward == rhs.canGoForward
  }
}

public enum WindowNavigationScope: Hashable, Sendable {
  case main
  case session
}

private struct WindowNavigationFocusKey: FocusedValueKey {
  typealias Value = WindowNavigationState
}

extension FocusedValues {
  public var windowNavigation: WindowNavigationState? {
    get { self[WindowNavigationFocusKey.self] }
    set { self[WindowNavigationFocusKey.self] = newValue }
  }
}

@MainActor
private final class WindowNavigationHandlers {
  var backHandler: (@MainActor () -> Void)?
  var forwardHandler: (@MainActor () -> Void)?
}

@MainActor
@Observable
public final class WindowCommandRoutingState {
  public var activeScope: WindowNavigationScope?
  public private(set) var activeSessionID: String?
  private var activeWindowID: ObjectIdentifier?
  private var sessionIDsByWindowID: [ObjectIdentifier: String] = [:]

  public init(activeScope: WindowNavigationScope? = nil) {
    self.activeScope = activeScope
  }

  public func activate(scope: WindowNavigationScope?, windowID: ObjectIdentifier) {
    let nextSessionID = sessionIDsByWindowID[windowID]
    guard
      activeScope != scope
        || activeWindowID != windowID
        || activeSessionID != nextSessionID
    else {
      return
    }
    activeScope = scope
    activeWindowID = windowID
    activeSessionID = nextSessionID
  }

  public func register(sessionID: String?, windowID: ObjectIdentifier) {
    // Short-circuit when nothing actually changes. `register` is called from
    // `WindowCommandScopeTrackingView.updateNSView`, and writing to the
    // `@Observable` storage on every invocation invalidates the SwiftUI graph,
    // which re-runs view body, which re-invokes updateNSView — infinite loop
    // and 100% CPU on launch.
    let existing = sessionIDsByWindowID[windowID]
    if existing != sessionID {
      if let sessionID {
        sessionIDsByWindowID[windowID] = sessionID
      } else {
        sessionIDsByWindowID.removeValue(forKey: windowID)
      }
    }
    guard activeWindowID == windowID else {
      return
    }
    let next = sessionIDsByWindowID[windowID]
    if activeSessionID != next {
      activeSessionID = next
    }
  }

  public func clear(windowID: ObjectIdentifier) {
    let removed = sessionIDsByWindowID.removeValue(forKey: windowID) != nil
    guard activeWindowID == windowID else {
      _ = removed
      return
    }
    if activeScope != nil { activeScope = nil }
    activeWindowID = nil
    if activeSessionID != nil { activeSessionID = nil }
  }
}
