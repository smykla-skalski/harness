import AppKit
import HarnessMonitorKit

extension PrimaryContentPagingResponderBridgeView {
  func registerWindowObserver(for window: NSWindow) {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { [weak self, weak window] event in
      guard let self, let window, self.isPagingEvent(event) else {
        return event
      }
      let windowMatch = event.window === window
      let fallbackMatch = event.window == nil && NSApp.keyWindow === window
      let eventTargetsWindow = windowMatch || fallbackMatch
      guard eventTargetsWindow else {
        return event
      }
      self.recordLocalPagingEvent(event, window: window)
      guard let action = self.pagingAction(for: event) else {
        return event
      }
      let shouldHandle = self.shouldHandleLocalPagingEvent(in: window)
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "local-key-monitor-decision",
        details: [
          "action": action.rawValue,
          "should_handle": String(shouldHandle),
          "window_first_responder": self.responderName(window.firstResponder),
        ]
      )
      guard shouldHandle else {
        return event
      }
      self.performPagingAction(action, sender: self)
      HarnessMonitorUITestTrace.record(
        component: "primary-content-focus",
        event: "local-key-monitor-handled",
        details: [
          "action": action.rawValue,
          "window_first_responder": self.responderName(window.firstResponder),
        ]
      )
      return nil
    }
    windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
          self.isActivationEnabled,
          self.currentRequest > 0,
          self.currentRequest != self.lastHandledRequest
        else {
          return
        }
        self.cancelPendingRequests()
        self.scheduleActivationAttempts(for: self.currentRequest)
      }
    }
    windowDidResignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.restoreSuppressedFocusRings()
      }
    }
  }

  func unregisterWindowObserver() {
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let windowDidBecomeKeyObserver {
      NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
      self.windowDidBecomeKeyObserver = nil
    }
    if let windowDidResignKeyObserver {
      NotificationCenter.default.removeObserver(windowDidResignKeyObserver)
      self.windowDidResignKeyObserver = nil
    }
  }
}
