import AppKit
import SwiftUI

struct SessionTimelineScrollStickinessConfigurator: NSViewRepresentable {
  let isEnabled: Bool

  func makeNSView(context: Context) -> ConfiguratorView {
    let view = ConfiguratorView()
    view.setEnabled(isEnabled)
    return view
  }

  func updateNSView(_ nsView: ConfiguratorView, context: Context) {
    nsView.setEnabled(isEnabled)
  }

  final class ConfiguratorView: NSView {
    private static let passThroughThreshold: CGFloat = 180
    private static let gestureResetInterval: TimeInterval = 0.45

    private var isEnabled = false
    private var isConfigurationScheduled = false
    private weak var configuredScrollView: NSScrollView?
    private weak var originalNextResponder: NSResponder?
    private var forwardedScrollDistance: CGFloat = 0
    private var forwardedScrollDirection: CGFloat = 0
    private var isPassingForwardedScroll = false
    private var lastForwardedScrollTimestamp: TimeInterval?

    deinit {
      MainActor.assumeIsolated {
        restoreResponderChain()
      }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil {
        restoreResponderChain()
      }
      super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      configureAfterLayout()
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      configureAfterLayout()
    }

    func setEnabled(_ isEnabled: Bool) {
      let didChange = self.isEnabled != isEnabled
      self.isEnabled = isEnabled
      if didChange || configuredScrollView?.window == nil {
        configureAfterLayout()
      }
      if !isEnabled {
        resetForwardingGate()
      }
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
      isEnabled && axis == .vertical
    }

    override func scrollWheel(with event: NSEvent) {
      guard shouldGateForwardedScroll(event) else {
        forward(event)
        return
      }

      resetForwardingGateIfNeeded(for: event)
      let direction = scrollDirection(for: event)
      if direction != forwardedScrollDirection {
        forwardedScrollDirection = direction
        forwardedScrollDistance = 0
        isPassingForwardedScroll = false
      }

      forwardedScrollDistance += abs(verticalDelta(for: event))
      lastForwardedScrollTimestamp = event.timestamp
      if isPassingForwardedScroll
        || forwardedScrollDistance >= Self.passThroughThreshold
      {
        isPassingForwardedScroll = true
        forward(event)
      }

      if event.phase.contains(.ended)
        || event.phase.contains(.cancelled)
        || event.momentumPhase.contains(.ended)
        || event.momentumPhase.contains(.cancelled)
      {
        resetForwardingGate()
      }
    }

    private func configureAfterLayout() {
      guard !isConfigurationScheduled else {
        return
      }
      isConfigurationScheduled = true
      DispatchQueue.main.async { [weak self] in
        self?.isConfigurationScheduled = false
        self?.configureEnclosingScrollView()
      }
    }

    private func configureEnclosingScrollView() {
      guard let scrollView = nearestScrollView() else {
        return
      }

      if configuredScrollView !== scrollView {
        restoreResponderChain()
        configuredScrollView = scrollView
      }
      applyIfNeeded(
        scrollView,
        verticalElasticity: isEnabled ? .allowed : .automatic
      )
      if isEnabled {
        installResponderGate(on: scrollView)
      } else {
        restoreResponderChain()
      }
    }

    private func applyIfNeeded(
      _ scrollView: NSScrollView,
      verticalElasticity: NSScrollView.Elasticity
    ) {
      if !scrollView.usesPredominantAxisScrolling {
        scrollView.usesPredominantAxisScrolling = true
      }
      if scrollView.verticalScrollElasticity != verticalElasticity {
        scrollView.verticalScrollElasticity = verticalElasticity
      }
      if scrollView.horizontalScrollElasticity != .none {
        scrollView.horizontalScrollElasticity = .none
      }
    }

    private func installResponderGate(on scrollView: NSScrollView) {
      guard scrollView.nextResponder !== self else {
        return
      }
      originalNextResponder = scrollView.nextResponder
      nextResponder = originalNextResponder
      scrollView.nextResponder = self
    }

    private func restoreResponderChain() {
      if configuredScrollView?.nextResponder === self {
        configuredScrollView?.nextResponder = originalNextResponder
      }
      nextResponder = nil
      originalNextResponder = nil
      resetForwardingGate()
    }

    private func shouldGateForwardedScroll(_ event: NSEvent) -> Bool {
      guard isEnabled else {
        return false
      }
      let verticalDelta = abs(verticalDelta(for: event))
      guard verticalDelta > 0 else {
        return false
      }
      return verticalDelta >= abs(horizontalDelta(for: event))
    }

    private func resetForwardingGateIfNeeded(for event: NSEvent) {
      if event.phase.contains(.began)
        || event.momentumPhase.contains(.began)
      {
        resetForwardingGate()
        return
      }

      guard let lastForwardedScrollTimestamp else {
        return
      }
      if event.timestamp - lastForwardedScrollTimestamp > Self.gestureResetInterval {
        resetForwardingGate()
      }
    }

    private func resetForwardingGate() {
      forwardedScrollDistance = 0
      forwardedScrollDirection = 0
      isPassingForwardedScroll = false
      lastForwardedScrollTimestamp = nil
    }

    private func scrollDirection(for event: NSEvent) -> CGFloat {
      verticalDelta(for: event) < 0 ? -1 : 1
    }

    private func verticalDelta(for event: NSEvent) -> CGFloat {
      event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
    }

    private func horizontalDelta(for event: NSEvent) -> CGFloat {
      event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
    }

    private func forward(_ event: NSEvent) {
      nextResponder?.scrollWheel(with: event)
    }

    private func nearestScrollView() -> NSScrollView? {
      if let configuredScrollView,
        configuredScrollView.window != nil
      {
        return configuredScrollView
      }

      if let enclosingScrollView {
        return enclosingScrollView
      }

      var candidate = superview
      while let view = candidate {
        if let scrollView = view as? NSScrollView {
          return scrollView
        }
        candidate = view.superview
      }
      return nil
    }
  }
}
