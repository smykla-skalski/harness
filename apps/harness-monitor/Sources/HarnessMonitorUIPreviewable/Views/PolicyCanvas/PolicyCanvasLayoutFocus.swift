import SwiftUI

@MainActor
public final class PolicyCanvasLayoutFocusDispatcher {
  public var reflowLayout: (() -> Void)?

  public init() {}

  public func performReflowLayout() {
    reflowLayout?()
  }
}

public struct PolicyCanvasLayoutFocus: Equatable {
  public let canReflow: Bool
  public let dispatcher: PolicyCanvasLayoutFocusDispatcher

  public init(
    canReflow: Bool,
    dispatcher: PolicyCanvasLayoutFocusDispatcher
  ) {
    self.canReflow = canReflow
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canReflow == rhs.canReflow
      && lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var harnessPolicyCanvasLayoutFocus: PolicyCanvasLayoutFocus?
}
