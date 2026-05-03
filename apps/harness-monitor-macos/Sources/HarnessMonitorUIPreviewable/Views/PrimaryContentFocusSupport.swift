import AppKit
import HarnessMonitorKit

final class PrimaryContentPagingResponderBridgeView: NSView {
  final class SuppressedFocusRingState {
    weak var view: NSView?
    let originalFocusRingType: NSFocusRingType

    init(view: NSView, originalFocusRingType: NSFocusRingType) {
      self.view = view
      self.originalFocusRingType = originalFocusRingType
    }
  }

  struct PagingScrollMetrics {
    let minimumY: CGFloat
    let maximumY: CGFloat
    let pageDistance: CGFloat
  }

  var currentRequest = 0
  var isActivationEnabled = false
  var lastHandledRequest = 0
  var pendingRequests: [DispatchWorkItem] = []
  var suppressedFocusRingStates: [SuppressedFocusRingState] = []
  var windowDidBecomeKeyObserver: NSObjectProtocol?
  var windowDidResignKeyObserver: NSObjectProtocol?
  var localKeyMonitor: Any?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    alphaValue = 0
    focusRingType = .none
    setAccessibilityHidden(true)
  }

  override var acceptsFirstResponder: Bool { true }

  override var canBecomeKeyView: Bool { true }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    restoreSuppressedFocusRings()
    cancelPendingRequests()
    unregisterWindowObserver()
    if let newWindow {
      registerWindowObserver(for: newWindow)
    }
  }

  func update(request: Int, isEnabled: Bool) {
    currentRequest = request
    isActivationEnabled = isEnabled
    cancelPendingRequests()
    if !isEnabled {
      restoreSuppressedFocusRings()
    }
    guard isEnabled, request > 0, request != lastHandledRequest else {
      return
    }
    scheduleActivationAttempts(for: request)
  }

  func scheduleActivationAttempts(for request: Int) {
    scheduleActivation(for: request, delay: .zero, isFinalAttempt: false)
    scheduleActivation(for: request, delay: 0.05, isFinalAttempt: false)
    scheduleActivation(for: request, delay: 0.2, isFinalAttempt: true)
  }

  func scheduleActivation(
    for request: Int,
    delay: TimeInterval,
    isFinalAttempt: Bool
  ) {
    let workItem = DispatchWorkItem { [weak self] in
      self?.activatePrimaryScrollResponder(
        for: request,
        isFinalAttempt: isFinalAttempt
      )
    }
    pendingRequests.append(workItem)
    if delay.isZero {
      DispatchQueue.main.async(execute: workItem)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }

  func activatePrimaryScrollResponder(
    for request: Int,
    isFinalAttempt: Bool
  ) {
    guard request != lastHandledRequest else {
      return
    }
    if let window, let scrollView = resolvedScrollView() {
      let activationSucceeded = makePagingFirstResponder(in: scrollView, window: window)
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "activation-attempt",
        details: [
          "request": String(request),
          "final_attempt": String(isFinalAttempt),
          "window_first_responder": responderName(window.firstResponder),
          "scroll_view": String(describing: type(of: scrollView)),
          "success": String(activationSucceeded),
        ]
      )
    } else {
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "activation-missing-scroll-view",
        details: [
          "request": String(request),
          "final_attempt": String(isFinalAttempt),
        ]
      )
    }
    if isFinalAttempt {
      lastHandledRequest = request
      pendingRequests.removeAll()
    }
  }

  func makePagingFirstResponder(in scrollView: NSScrollView, window: NSWindow) -> Bool {
    suppressFocusRings(
      on: [
        scrollView,
        scrollView.contentView,
        scrollView.documentView,
      ]
    )
    // SwiftUI's hosted document view is not a reliable first-responder target
    // for paging keys, so prefer the bridge itself and fall back only if needed.
    let candidates: [NSResponder?] = [
      self,
      scrollView.documentView,
      scrollView,
      scrollView.contentView,
    ]
    for candidate in candidates {
      guard let candidate else {
        continue
      }
      if window.firstResponder === candidate {
        HarnessMonitorUITestTrace.record(
          component: "primary-content-focus",
          event: "candidate-already-focused",
          details: [
            "candidate": responderName(candidate),
            "window_first_responder": responderName(window.firstResponder),
          ]
        )
        return true
      }
      let success = window.makeFirstResponder(candidate)
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "make-first-responder",
        details: [
          "candidate": responderName(candidate),
          "success": String(success),
          "window_first_responder": responderName(window.firstResponder),
        ]
      )
      if success {
        return true
      }
    }
    return false
  }

  override func keyDown(with event: NSEvent) {
    guard handlePagingKey(event) else {
      super.keyDown(with: event)
      return
    }
  }

  override func pageDown(_ sender: Any?) {
    performPagingAction(.pageDown, sender: sender)
  }

  override func pageUp(_ sender: Any?) {
    performPagingAction(.pageUp, sender: sender)
  }

  override func scrollPageDown(_ sender: Any?) {
    performPagingAction(.scrollPageDown, sender: sender)
  }

  override func scrollPageUp(_ sender: Any?) {
    performPagingAction(.scrollPageUp, sender: sender)
  }

  func responderName(_ responder: NSResponder?) -> String {
    guard let responder else {
      return "nil"
    }
    return String(describing: type(of: responder))
  }

  func specialKeyName(_ specialKey: NSEvent.SpecialKey?) -> String {
    guard let specialKey else {
      return "nil"
    }
    return String(describing: specialKey)
  }

  func coordinateLabel(_ coordinate: CGFloat) -> String {
    String(format: "%.1f", coordinate)
  }

  func optionalCoordinateLabel(_ coordinate: CGFloat?) -> String {
    guard let coordinate else {
      return "nil"
    }
    return coordinateLabel(coordinate)
  }

  func shouldHandleLocalPagingEvent(in window: NSWindow) -> Bool {
    guard isActivationEnabled else {
      return false
    }
    guard let firstResponder = window.firstResponder else {
      return true
    }
    if firstResponder === self || firstResponder === window {
      return true
    }
    return !isTextInputResponder(firstResponder)
      && resolvedScrollView() != nil
      && responderName(firstResponder) == "AppKitWindow"
  }

  func isTextInputResponder(_ responder: NSResponder) -> Bool {
    if responder is NSTextView {
      return true
    }
    guard let view = responder as? NSView else {
      return false
    }
    return view is NSTextField || view is NSText
  }

  func recordLocalPagingEvent(_ event: NSEvent, window: NSWindow) {
    let scrollView = resolvedScrollView()
    let visibleRect = scrollView?.documentVisibleRect
    let documentHeight = scrollView?.documentView?.bounds.height
    let documentView = scrollView?.documentView
    HarnessMonitorUITestTrace.record(
      component: "primary-content-focus",
      event: "local-key-monitor",
      details: [
        "key_code": String(event.keyCode),
        "special_key": specialKeyName(event.specialKey),
        "characters": event.charactersIgnoringModifiers ?? "",
        "shift": String(event.modifierFlags.contains(.shift)),
        "window_first_responder": responderName(window.firstResponder),
        "window_initial_first_responder": responderName(window.initialFirstResponder),
        "bridge_is_first_responder": String(window.firstResponder === self),
        "app_key_window_matches": String(NSApp.keyWindow === window),
        "scroll_view": scrollView.map { String(describing: type(of: $0)) } ?? "nil",
        "scroll_accepts_first_responder": String(scrollView?.acceptsFirstResponder ?? false),
        "scroll_can_become_key_view": String(scrollView?.canBecomeKeyView ?? false),
        "document_view": documentView.map { String(describing: type(of: $0)) } ?? "nil",
        "document_accepts_first_responder": String(documentView?.acceptsFirstResponder ?? false),
        "document_can_become_key_view": String(documentView?.canBecomeKeyView ?? false),
        "content_inset_top": optionalCoordinateLabel(scrollView?.contentInsets.top),
        "content_inset_bottom": optionalCoordinateLabel(scrollView?.contentInsets.bottom),
        "visible_y": optionalCoordinateLabel(visibleRect?.minY),
        "visible_height": optionalCoordinateLabel(visibleRect?.height),
        "document_height": optionalCoordinateLabel(documentHeight),
      ]
    )
  }

  func cancelPendingRequests() {
    for request in pendingRequests {
      request.cancel()
    }
    pendingRequests.removeAll()
  }
}

// Two callers today (main + workspace). When a third caller appears OR either
// caller needs a second `extraSuppressor`, migrate to a `FocusedValues` entry
// (`\.harnessPrimaryContentResetSuppression`, Phase 2 in the parity plan) and
// delete this helper. Do not grow the parameter list.
@MainActor
func shouldSuppressPrimaryContentFocusReset(
  preservesPrimaryContentFocus: Bool,
  hasFocusedEditorField: Bool,
  hasPresentedSheet: Bool,
  hasPendingConfirmation: Bool,
  extraSuppressor: Bool = false
) -> Bool {
  if preservesPrimaryContentFocus { return true }
  if hasFocusedEditorField { return true }
  if hasPresentedSheet { return true }
  if hasPendingConfirmation { return true }
  return extraSuppressor
}
