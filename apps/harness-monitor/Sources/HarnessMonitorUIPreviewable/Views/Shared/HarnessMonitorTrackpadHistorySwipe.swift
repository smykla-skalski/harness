import AppKit
import HarnessMonitorKit
import SwiftUI

enum HarnessTrackpadHistoryDirection: CGFloat, Sendable {
  case forward = -1
  case back = 1

  static let commitThreshold: CGFloat = 0.32

  static func resolve(
    gestureAmount: CGFloat,
    canGoBack: Bool,
    canGoForward: Bool
  ) -> Self? {
    if gestureAmount >= commitThreshold, canGoBack {
      return .back
    }
    if gestureAmount <= -commitThreshold, canGoForward {
      return .forward
    }
    return nil
  }

  @MainActor func navigate(using navigation: WindowNavigationState) {
    switch self {
    case .back:
      navigation.navigateBack()
    case .forward:
      navigation.navigateForward()
    }
  }
}

extension View {
  /// AppKit exception: Safari-like two-finger history swipe relies on
  /// `NSEvent.trackSwipeEvent`, which SwiftUI does not expose directly. The
  /// bridge sits in an `.overlay` so the interactive snapshot renders above the
  /// live content, and a window-scoped scroll monitor drives detection — the
  /// overlay opts out of hit-testing, so it never steals clicks or scrolls.
  func harnessTrackpadHistorySwipe(
    navigation: WindowNavigationState,
    isEnabled: Bool
  ) -> some View {
    modifier(
      HarnessTrackpadHistorySwipeModifier(
        navigation: navigation,
        isEnabled: isEnabled
      )
    )
  }
}

private struct HarnessTrackpadHistorySwipeModifier: ViewModifier {
  let navigation: WindowNavigationState
  let isEnabled: Bool

  func body(content: Content) -> some View {
    content.overlay(
      HarnessTrackpadHistorySwipeBridge(
        navigation: navigation,
        isEnabled: isEnabled
      )
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    )
  }
}

private struct HarnessTrackpadHistorySwipeBridge: NSViewRepresentable {
  let navigation: WindowNavigationState
  let isEnabled: Bool

  func makeNSView(context: Context) -> HarnessTrackpadHistorySwipeNSView {
    let view = HarnessTrackpadHistorySwipeNSView()
    view.update(navigation: navigation, isEnabled: isEnabled)
    return view
  }

  func updateNSView(_ nsView: HarnessTrackpadHistorySwipeNSView, context: Context) {
    nsView.update(navigation: navigation, isEnabled: isEnabled)
  }

  static func dismantleNSView(
    _ nsView: HarnessTrackpadHistorySwipeNSView,
    coordinator: ()
  ) {
    nsView.stopMonitoring()
  }
}

final class HarnessTrackpadHistorySwipeNSView: NSView {
  private var navigation = WindowNavigationState()
  nonisolated(unsafe) private var monitor: Any?
  private var isEnabled = false
  var monitoredWindow: NSWindow?
  var isTrackingGesture = false
  var lastGestureAmount: CGFloat = 0
  var backdropLayer: CALayer?
  var snapshotLayer: CALayer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .duringViewResize
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    // MainActor teardown runs in dismantleNSView; deinit only does the
    // thread-safe inline removal of the event monitor to avoid a leak.
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  /// The overlay is purely decorative: detection runs through the window-scoped
  /// scroll monitor, so the view stays out of hit-testing and clicks, vertical
  /// scrolls, and non-swipe gestures fall straight through to the content.
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func update(navigation: WindowNavigationState, isEnabled: Bool) {
    self.navigation = navigation
    self.isEnabled = isEnabled
    if isEnabled {
      startMonitoringIfNeeded()
    } else {
      stopMonitoring()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window !== monitoredWindow {
      stopMonitoring()
      startMonitoringIfNeeded()
    }
  }

  func stopMonitoring() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    monitoredWindow = nil
    cancelActiveTracking()
  }

  private func startMonitoringIfNeeded() {
    guard monitor == nil, isEnabled, let window else {
      return
    }

    monitoredWindow = window
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
      self?.handleMonitored(event) ?? event
    }
  }

  private func handleMonitored(_ event: NSEvent) -> NSEvent? {
    guard event.type == .scrollWheel else {
      return event
    }
    guard let monitoredWindow, event.window === monitoredWindow else {
      return event
    }
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
      return event
    }

    if isTrackingGesture {
      return nil
    }
    guard shouldStartTracking(with: event) else {
      return event
    }
    // A surface that pans horizontally (the policy canvas) wins the gesture
    // while the pointer is over it; the swipe still fires everywhere else.
    if HarnessTrackpadSwipeOptOutRegistry.shared.suppressesSwipe(
      at: event.locationInWindow,
      in: monitoredWindow
    ) {
      return event
    }

    beginSwipeTracking(with: event)
    return nil
  }

  private func shouldStartTracking(with event: NSEvent) -> Bool {
    guard isEnabled else {
      return false
    }
    // Honor the system "swipe between pages" preference; when it is off the
    // gesture belongs to the OS, not to us.
    guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
      return false
    }
    guard event.phase == .began else {
      return false
    }
    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
      return false
    }
    return navigation.canGoBack || navigation.canGoForward
  }

  private func beginSwipeTracking(with event: NSEvent) {
    beginTrackingGesture()

    let canGoBack = navigation.canGoBack
    let canGoForward = navigation.canGoForward
    event.trackSwipeEvent(
      options: [.lockDirection, .clampGestureAmount],
      dampenAmountThresholdMin: canGoForward ? -1 : 0,
      max: canGoBack ? 1 : 0
    ) { [weak self] gestureAmount, phase, _, stop in
      guard let self else {
        stop.pointee = true
        return
      }

      self.lastGestureAmount = gestureAmount
      self.applyTrackingEffect(gestureAmount: gestureAmount)

      switch phase {
      case .cancelled:
        self.finishTrackingGesture(committedDirection: nil)
        stop.pointee = true
      case .ended:
        let direction = HarnessTrackpadHistoryDirection.resolve(
          gestureAmount: gestureAmount,
          canGoBack: canGoBack,
          canGoForward: canGoForward
        )
        self.finishTrackingGesture(committedDirection: direction)
        stop.pointee = true
      default:
        break
      }
    }
  }

  private func beginTrackingGesture() {
    isTrackingGesture = true
    lastGestureAmount = 0
    prepareTrackingLayersIfNeeded()
    applyTrackingEffect(gestureAmount: 0)
  }

  private func cancelActiveTracking() {
    isTrackingGesture = false
    lastGestureAmount = 0
    cleanupTrackingLayers()
  }

  private func finishTrackingGesture(
    committedDirection: HarnessTrackpadHistoryDirection?
  ) {
    isTrackingGesture = false
    let destinationOffset =
      (committedDirection?.rawValue ?? 0)
      * bounds.width
      * (
        committedDirection == nil
          ? 0
          : HarnessTrackpadHistoryEffect.commitTravelFactor
      )
    let duration =
      committedDirection == nil
        ? HarnessTrackpadHistoryEffect.cancelDuration
        : HarnessTrackpadHistoryEffect.commitDuration
    let timing =
      committedDirection == nil
        ? CAMediaTimingFunctionName.easeOut
        : CAMediaTimingFunctionName.easeInEaseOut

    animateTrackingLayers(
      to: destinationOffset,
      duration: duration,
      timingFunctionName: timing
    ) { [weak self] in
      guard let self else { return }
      self.cleanupTrackingLayers()
      committedDirection?.navigate(using: self.navigation)
    }
  }
}
