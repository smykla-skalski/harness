import HarnessMonitorPolicyCanvasAlgorithms
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

@MainActor
public final class PolicyCanvasInspectorFocusDispatcher {
  public var toggleInspector: (() -> Void)?

  public init() {}

  public func performToggleInspector() {
    toggleInspector?()
  }
}

public struct PolicyCanvasInspectorFocus: Equatable {
  public let isVisible: Bool
  public let canToggle: Bool
  public let dispatcher: PolicyCanvasInspectorFocusDispatcher

  public init(
    isVisible: Bool,
    canToggle: Bool,
    dispatcher: PolicyCanvasInspectorFocusDispatcher
  ) {
    self.isVisible = isVisible
    self.canToggle = canToggle
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isVisible == rhs.isVisible
      && lhs.canToggle == rhs.canToggle
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
  public let save: PolicyCanvasSaveFocus
  public let inspector: PolicyCanvasInspectorFocus

  public init(
    zoom: PolicyCanvasZoomFocus,
    layout: PolicyCanvasLayoutFocus,
    save: PolicyCanvasSaveFocus,
    inspector: PolicyCanvasInspectorFocus
  ) {
    self.zoom = zoom
    self.layout = layout
    self.save = save
    self.inspector = inspector
  }
}
