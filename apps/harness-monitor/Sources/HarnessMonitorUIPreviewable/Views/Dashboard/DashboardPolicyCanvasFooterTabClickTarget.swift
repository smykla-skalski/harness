import AppKit
import SwiftUI

struct DashboardPolicyCanvasFooterTabClickTarget: NSViewRepresentable {
  let singleClickDelay: Duration
  let onHover: @MainActor (Bool) -> Void
  let singleClick: @MainActor () -> Void
  let doubleClick: @MainActor () -> Void

  init(
    singleClickDelay: Duration = Self.defaultSingleClickDelay,
    onHover: @escaping @MainActor (Bool) -> Void,
    singleClick: @escaping @MainActor () -> Void,
    doubleClick: @escaping @MainActor () -> Void
  ) {
    self.singleClickDelay = singleClickDelay
    self.onHover = onHover
    self.singleClick = singleClick
    self.doubleClick = doubleClick
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      singleClickDelay: singleClickDelay,
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
      singleClickDelay: singleClickDelay,
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
    coordinator.cancelPendingSingleClick()
    coordinator.handleHover(false)
    view.coordinator = nil
  }

  private static var defaultSingleClickDelay: Duration {
    let milliseconds = max(1, Int64((NSEvent.doubleClickInterval * 1000).rounded(.up)))
    return .milliseconds(milliseconds)
  }

  @MainActor
  final class Coordinator {
    private var singleClickDelay: Duration
    private var onHover: @MainActor (Bool) -> Void
    private var singleClick: @MainActor () -> Void
    private var doubleClick: @MainActor () -> Void
    private var pendingSingleClickTask: Task<Void, Never>?

    init(
      singleClickDelay: Duration,
      onHover: @escaping @MainActor (Bool) -> Void,
      singleClick: @escaping @MainActor () -> Void,
      doubleClick: @escaping @MainActor () -> Void
    ) {
      self.singleClickDelay = singleClickDelay
      self.onHover = onHover
      self.singleClick = singleClick
      self.doubleClick = doubleClick
    }

    func update(
      singleClickDelay: Duration,
      onHover: @escaping @MainActor (Bool) -> Void,
      singleClick: @escaping @MainActor () -> Void,
      doubleClick: @escaping @MainActor () -> Void
    ) {
      self.singleClickDelay = singleClickDelay
      self.onHover = onHover
      self.singleClick = singleClick
      self.doubleClick = doubleClick
    }

    func handleClick(count: Int) {
      if count >= 2 {
        cancelPendingSingleClick()
        doubleClick()
        return
      }
      scheduleSingleClick()
    }

    func handleHover(_ hovering: Bool) {
      onHover(hovering)
    }

    func cancelPendingSingleClick() {
      pendingSingleClickTask?.cancel()
      pendingSingleClickTask = nil
    }

    private func scheduleSingleClick() {
      cancelPendingSingleClick()
      let delay = singleClickDelay
      pendingSingleClickTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard let self, !Task.isCancelled else {
          return
        }
        pendingSingleClickTask = nil
        singleClick()
      }
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
      coordinator?.cancelPendingSingleClick()
      coordinator?.handleHover(false)
    }
    super.viewWillMove(toWindow: newWindow)
  }
}
