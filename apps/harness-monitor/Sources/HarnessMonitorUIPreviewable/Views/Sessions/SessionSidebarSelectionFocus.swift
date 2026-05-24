import SwiftUI

@MainActor
public final class SessionSidebarSelectionDispatcher {
  public var selectAll: (() -> Void)?
  public var clearSelection: (() -> Void)?
  public var deleteSelection: (() -> Void)?

  public init() {}

  public func performSelectAll() {
    selectAll?()
  }

  public func performClearSelection() {
    clearSelection?()
  }

  public func performDeleteSelection() {
    deleteSelection?()
  }
}

public struct SessionSidebarSelectionFocus: Equatable {
  public let hasMultiSelection: Bool
  public let canDelete: Bool
  public let dispatcher: SessionSidebarSelectionDispatcher

  public init(
    hasMultiSelection: Bool,
    canDelete: Bool,
    dispatcher: SessionSidebarSelectionDispatcher
  ) {
    self.hasMultiSelection = hasMultiSelection
    self.canDelete = canDelete
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hasMultiSelection == rhs.hasMultiSelection
      && lhs.canDelete == rhs.canDelete
      && lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var harnessSessionSidebarSelection: SessionSidebarSelectionFocus?
}
