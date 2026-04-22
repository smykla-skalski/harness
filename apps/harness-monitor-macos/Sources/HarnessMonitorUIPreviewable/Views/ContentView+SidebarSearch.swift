import SwiftUI

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
  public let dispatcher: HarnessSidebarSearchFocusDispatcher

  public init(isAvailable: Bool, dispatcher: HarnessSidebarSearchFocusDispatcher) {
    self.isAvailable = isAvailable
    self.dispatcher = dispatcher
  }

  @MainActor
  public func invoke() {
    guard isAvailable else { return }
    dispatcher.invoke()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isAvailable == rhs.isAvailable && lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var harnessSidebarSearchFocusAction: HarnessSidebarSearchFocus?
}
