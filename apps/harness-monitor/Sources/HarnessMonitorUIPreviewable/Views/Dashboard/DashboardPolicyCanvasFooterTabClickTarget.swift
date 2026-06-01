import AppKit
import SwiftUI

struct DashboardPolicyCanvasFooterTabClickTarget: NSViewRepresentable {
  let onHover: @MainActor (Bool) -> Void
  let singleClick: @MainActor () -> Void
  let doubleClick: @MainActor () -> Void

  init(
    onHover: @escaping @MainActor (Bool) -> Void,
    singleClick: @escaping @MainActor () -> Void,
    doubleClick: @escaping @MainActor () -> Void
  ) {
    self.onHover = onHover
    self.singleClick = singleClick
    self.doubleClick = doubleClick
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onHover: onHover,
      singleClick: singleClick,
      doubleClick: doubleClick
    )
  }

  func makeNSView(context: Context) -> DashboardPolicyCanvasFooterTabClickTargetView {
    let view = DashboardPolicyCanvasFooterTabClickTargetView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(
    _ view: DashboardPolicyCanvasFooterTabClickTargetView,
    context: Context
  ) {
    context.coordinator.update(
      onHover: onHover,
      singleClick: singleClick,
      doubleClick: doubleClick
    )
    view.coordinator = context.coordinator
  }

  static func dismantleNSView(
    _ view: DashboardPolicyCanvasFooterTabClickTargetView,
    coordinator: Coordinator
  ) {
    coordinator.handleHover(false)
    view.coordinator = nil
  }

  @MainActor
  final class Coordinator {
    private var onHover: @MainActor (Bool) -> Void
    private var singleClick: @MainActor () -> Void
    private var doubleClick: @MainActor () -> Void

    init(
      onHover: @escaping @MainActor (Bool) -> Void,
      singleClick: @escaping @MainActor () -> Void,
      doubleClick: @escaping @MainActor () -> Void
    ) {
      self.onHover = onHover
      self.singleClick = singleClick
      self.doubleClick = doubleClick
    }

    func update(
      onHover: @escaping @MainActor (Bool) -> Void,
      singleClick: @escaping @MainActor () -> Void,
      doubleClick: @escaping @MainActor () -> Void
    ) {
      self.onHover = onHover
      self.singleClick = singleClick
      self.doubleClick = doubleClick
    }

    func handleClick(count: Int) {
      if count >= 2 {
        doubleClick()
        return
      }
      singleClick()
    }

    func handleHover(_ hovering: Bool) {
      onHover(hovering)
    }
  }
}

@MainActor
final class DashboardPolicyCanvasFooterTabClickTargetView: NSView {
  weak var coordinator: DashboardPolicyCanvasFooterTabClickTarget.Coordinator?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.activeInActiveApp, .inVisibleRect, .mouseEnteredAndExited],
        owner: self
      )
    )
  }

  override func mouseDown(with event: NSEvent) {
    coordinator?.handleClick(count: event.clickCount)
  }

  override func mouseEntered(with event: NSEvent) {
    coordinator?.handleHover(true)
  }

  override func mouseExited(with event: NSEvent) {
    coordinator?.handleHover(false)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      coordinator?.handleHover(false)
    }
    super.viewWillMove(toWindow: newWindow)
  }
}
