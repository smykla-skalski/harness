import SwiftUI

// Route-aware label for the Cmd-F menu item. Four callers use this type today
// (dashboard window, workspace decision route, workspace non-decision route,
// and the unified session-window search). When a fifth caller appears, widen
// the enum here.
public enum HarnessSidebarSearchMenuLabel: Sendable, Equatable {
  case findInSessions
  case findInDecisions
  case findGeneric
  case findInSession

  public var localizedTitle: LocalizedStringKey {
    switch self {
    case .findInSessions: "Find in Sessions"
    case .findInDecisions: "Find in Decisions"
    case .findGeneric: "Find"
    case .findInSession: "Find in Session"
    }
  }
}

@MainActor
public final class HarnessSidebarSearchFocusDispatcher {
  public var handler: (() -> Void)?

  public init() {}

  public func invoke() {
    handler?()
  }
}

public struct HarnessSidebarSearchFocus: Equatable {
  public let isAvailable: Bool
  public let menuLabel: HarnessSidebarSearchMenuLabel
  public let dispatcher: HarnessSidebarSearchFocusDispatcher

  public init(
    isAvailable: Bool,
    menuLabel: HarnessSidebarSearchMenuLabel,
    dispatcher: HarnessSidebarSearchFocusDispatcher
  ) {
    self.isAvailable = isAvailable
    self.menuLabel = menuLabel
    self.dispatcher = dispatcher
  }

  @MainActor
  public func invoke() {
    guard isAvailable else { return }
    dispatcher.invoke()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isAvailable == rhs.isAvailable
      && lhs.menuLabel == rhs.menuLabel
      && lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var harnessSidebarSearchFocusAction: HarnessSidebarSearchFocus?
  @Entry public var harnessSidebarVisibilityRequest: HarnessSidebarVisibilityRequest?
}

extension View {
  func harnessFocusedSceneValue<Value: Equatable>(
    _ keyPath: WritableKeyPath<FocusedValues, Value?>,
    _ value: Value?
  ) -> some View {
    modifier(HarnessDeferredFocusedSceneValue(keyPath: keyPath, value: value))
  }
}

private struct HarnessDeferredFocusedSceneValue<Value: Equatable>: ViewModifier {
  let keyPath: WritableKeyPath<FocusedValues, Value?>
  let value: Value?
  @State private var publishedValue: Value?
  @State private var didPublishInitialValue = false

  func body(content: Content) -> some View {
    content
      .focusedSceneValue(keyPath, publishedValue)
      .task(id: value) {
        await publish(value)
      }
  }

  @MainActor
  private func publish(_ value: Value?) async {
    if !didPublishInitialValue {
      didPublishInitialValue = true
      try? await Task.sleep(for: .milliseconds(120))
    } else {
      await Task.yield()
    }
    guard !Task.isCancelled, publishedValue != value else { return }
    publishedValue = value
  }
}

@MainActor
public final class HarnessSidebarVisibilityExpander {
  public var handler: (() -> Void)?
  public init() {}
  public func expand() { handler?() }
}

public struct HarnessSidebarVisibilityRequest: Equatable {
  public let expander: HarnessSidebarVisibilityExpander

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.expander === rhs.expander
  }
}
