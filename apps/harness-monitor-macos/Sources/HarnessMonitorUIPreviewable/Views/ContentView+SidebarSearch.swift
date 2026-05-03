import SwiftUI

// Route-aware label for the Cmd-F menu item. Three callers use this type today
// (main window, workspace decision route, workspace non-decision route).
// When a fourth caller appears, widen the enum here.
public enum HarnessSidebarSearchMenuLabel: Sendable, Equatable {
  case findInSessions
  case findInDecisions
  case findGeneric

  public var localizedTitle: LocalizedStringKey {
    switch self {
    case .findInSessions: "Find in Sessions"
    case .findInDecisions: "Find in Decisions"
    case .findGeneric: "Find"
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
}
