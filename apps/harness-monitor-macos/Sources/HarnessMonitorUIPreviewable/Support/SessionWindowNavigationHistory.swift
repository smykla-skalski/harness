import Observation

@MainActor
@Observable
public final class SessionWindowNavigationHistory {
  public private(set) var backStack: [SessionSelection] = []
  public private(set) var forwardStack: [SessionSelection] = []

  public init() {}

  public var canGoBack: Bool { !backStack.isEmpty }
  public var canGoForward: Bool { !forwardStack.isEmpty }

  public func record(_ selection: SessionSelection) {
    backStack.append(selection)
    forwardStack.removeAll()
  }

  public func popBack(current: SessionSelection) -> SessionSelection? {
    guard let previous = backStack.popLast() else { return nil }
    forwardStack.append(current)
    return previous
  }

  public func popForward(current: SessionSelection) -> SessionSelection? {
    guard let next = forwardStack.popLast() else { return nil }
    backStack.append(current)
    return next
  }
}

@MainActor
@Observable
public final class SessionAttentionState {
  public var pendingDecisionCount = 0

  public init() {}
}
