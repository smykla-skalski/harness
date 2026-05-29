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
  /// Publish one Policy Canvas-focused value so SwiftUI does not receive
  /// multiple same-frame FocusedValue updates from the same scene surface.
  @Entry public var harnessPolicyCanvasCommandFocus: PolicyCanvasCommandFocus?
}

public struct PolicyCanvasCommandFocus: Equatable {
  public let zoom: PolicyCanvasZoomFocus
  public let layout: PolicyCanvasLayoutFocus

  public init(
    zoom: PolicyCanvasZoomFocus,
    layout: PolicyCanvasLayoutFocus
  ) {
    self.zoom = zoom
    self.layout = layout
  }
}
