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

private enum HarnessTrackpadHistoryEffect {
  static let previewTravelFactor: CGFloat = 0.78
  static let commitTravelFactor: CGFloat = 1.04
  static let cancelDuration: CFTimeInterval = 0.16
  static let commitDuration: CFTimeInterval = 0.22

  static func backdropOpacity(for progress: CGFloat) -> Float {
    let clamped = min(max(progress, 0), 1)
    return Float(0.18 + (clamped * 0.42))
  }
}

extension View {
  /// AppKit exception: Safari-like two-finger history swipe relies on
  /// `NSEvent.trackSwipeEvent`, which SwiftUI does not expose directly.
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
    content.background(
      HarnessTrackpadHistorySwipeBridge(
        navigation: navigation,
        isEnabled: isEnabled
      )
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

private final class HarnessTrackpadHistorySwipeNSView: NSView {
  private var navigation = WindowNavigationState()
  nonisolated(unsafe) private var monitor: Any?
  private weak var monitoredWindow: NSWindow?
  private var isEnabled = false
  private var isTrackingGesture = false
  private var lastGestureAmount: CGFloat = 0
  private var backdropLayer: CALayer?
  private var snapshotLayer: CALayer?

  override var acceptsFirstResponder: Bool { true }

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

  override func wantsScrollEventsForSwipeTracking(on axis: NSEvent.GestureAxis) -> Bool {
    axis == .horizontal
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

  override func scrollWheel(with event: NSEvent) {
    guard shouldStartTracking(with: event) else {
      return
    }

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

    scrollWheel(with: event)
    return nil
  }

  private func shouldStartTracking(with event: NSEvent) -> Bool {
    guard isEnabled else {
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

  private func prepareTrackingLayersIfNeeded() {
    guard backdropLayer == nil, snapshotLayer == nil else {
      return
    }
    guard let layer else {
      return
    }

    let backdrop = CALayer()
    backdrop.frame = bounds
    var backdropColor = NSColor.underPageBackgroundColor.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      backdropColor = NSColor.underPageBackgroundColor.cgColor
    }
    backdrop.backgroundColor = backdropColor
    backdrop.opacity = 0

    layer.addSublayer(backdrop)
    backdropLayer = backdrop

    if let snapshot = makeSnapshotLayer() {
      layer.addSublayer(snapshot)
      snapshotLayer = snapshot
    }
  }

  private func cleanupTrackingLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.backgroundColor = nil
    backdropLayer?.removeFromSuperlayer()
    snapshotLayer?.removeFromSuperlayer()
    backdropLayer = nil
    snapshotLayer = nil
    CATransaction.commit()
  }

  private func makeSnapshotLayer() -> CALayer? {
    guard bounds.width > 1, bounds.height > 1 else {
      return nil
    }
    guard let container = superview else {
      return nil
    }
    let captureRect = frame.integral
    guard let bitmap = container.bitmapImageRepForCachingDisplay(in: captureRect) else {
      return nil
    }

    let previousHidden = isHidden
    isHidden = true
    container.cacheDisplay(in: captureRect, to: bitmap)
    isHidden = previousHidden

    let image = NSImage(size: captureRect.size)
    image.addRepresentation(bitmap)

    let snapshot = CALayer()
    snapshot.frame = bounds
    snapshot.contents = image
    snapshot.contentsScale =
      monitoredWindow?.backingScaleFactor
      ?? window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    snapshot.shadowOpacity = 0.18
    snapshot.shadowRadius = 20
    snapshot.shadowOffset = CGSize(width: -8, height: 0)
    snapshot.shadowPath = CGPath(rect: bounds, transform: nil)
    return snapshot
  }

  private func applyTrackingEffect(gestureAmount: CGFloat) {
    let progress = max(-1, min(1, gestureAmount))
    let offset = progress * bounds.width * HarnessTrackpadHistoryEffect.previewTravelFactor

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
    snapshotLayer?.shadowOffset = CGSize(width: offset >= 0 ? -8 : 8, height: 0)
    backdropLayer?.opacity = HarnessTrackpadHistoryEffect.backdropOpacity(for: abs(progress))
    CATransaction.commit()
  }

  private func animateTrackingLayers(
    to offset: CGFloat,
    duration: CFTimeInterval,
    timingFunctionName: CAMediaTimingFunctionName,
    completion: @escaping () -> Void
  ) {
    guard backdropLayer != nil || snapshotLayer != nil else {
      completion()
      return
    }

    let currentOffset =
      lastGestureAmount
      * bounds.width
      * HarnessTrackpadHistoryEffect.previewTravelFactor

    CATransaction.begin()
    CATransaction.setCompletionBlock(completion)

    if let snapshotLayer {
      let animation = CABasicAnimation(keyPath: "transform.translation.x")
      animation.fromValue = currentOffset
      animation.toValue = offset
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
      snapshotLayer.add(animation, forKey: "trackpad-history-translate")
      snapshotLayer.transform = CATransform3DMakeTranslation(offset, 0, 0)
    }

    if let backdropLayer {
      let animation = CABasicAnimation(keyPath: "opacity")
      animation.fromValue = backdropLayer.presentation()?.opacity ?? backdropLayer.opacity
      animation.toValue = 0
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
      backdropLayer.add(animation, forKey: "trackpad-history-backdrop")
      backdropLayer.opacity = 0
    }

    CATransaction.commit()
  }
}
