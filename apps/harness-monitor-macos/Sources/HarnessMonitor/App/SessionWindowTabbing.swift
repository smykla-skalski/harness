import AppKit
import HarnessMonitorUIPreviewable
import SwiftUI
import os

struct SessionWindowTabbing: ViewModifier {
  let isSessionWindow: Bool
  @AppStorage(SessionWindowTabbingPreference.storageKey)
  private var preferenceRawValue = SessionWindowTabbingPreference.defaultValue.rawValue

  private var preference: SessionWindowTabbingPreference {
    SessionWindowTabbingPreference.resolved(rawValue: preferenceRawValue)
  }

  func body(content: Content) -> some View {
    content.background(
      SessionWindowTabbingAccessor(
        configuration: .init(
          isSessionWindow: isSessionWindow,
          preference: preference
        )
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    )
  }
}

private struct SessionWindowTabbingAccessor: NSViewRepresentable {
  struct Configuration: Equatable {
    let isSessionWindow: Bool
    let preference: SessionWindowTabbingPreference
  }

  let configuration: Configuration

  func makeNSView(context: Context) -> AccessorView {
    let view = AccessorView()
    view.configuration = configuration
    return view
  }

  func updateNSView(_ nsView: AccessorView, context: Context) {
    nsView.configuration = configuration
    nsView.applyWindowTabbing()
  }
}

private final class AccessorView: NSView {
  private static let log = Logger(
    subsystem: "io.harnessmonitor",
    category: "SessionWindowTabbing"
  )
  private static let sessionTabbingIdentifier = "io.harnessmonitor.session"

  var configuration = SessionWindowTabbingAccessor.Configuration(
    isSessionWindow: false,
    preference: .system
  )

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerWindowObservers()
    applyWindowTabbing()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    applyWindowTabbing()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    NotificationCenter.default.removeObserver(self)
  }

  private func registerWindowObservers() {
    guard let window else { return }
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
    ]
    for name in names {
      center.addObserver(
        self,
        selector: #selector(reapplyWindowTabbingFromNotification(_:)),
        name: name,
        object: window
      )
    }
  }

  @objc private func reapplyWindowTabbingFromNotification(_ note: Notification) {
    applyWindowTabbing()
  }

  func applyWindowTabbing() {
    guard let window else {
      return
    }
    if configuration.isSessionWindow {
      window.tabbingIdentifier = Self.sessionTabbingIdentifier
      window.tabbingMode = tabbingMode(for: configuration.preference)
      guard window.tabbingIdentifier == Self.sessionTabbingIdentifier else {
        Self.log.warning("Session tabbing identifier unavailable; falling back to standalone windows")
        window.tabbingMode = .automatic
        return
      }
      applyTitlebarChromeOverrides(to: window)
    } else {
      window.tabbingIdentifier = ""
      window.tabbingMode = .disallowed
    }
  }

  /// Setting `tabbingIdentifier` flips AppKit into a tabbable-window toolbar
  /// mode that draws an opaque titlebar with a baseline separator under the
  /// tab strip, masking the Liquid Glass blur and the SessionTitleBlurChrome
  /// status backdrop. AppKit also re-applies its defaults whenever a new tab
  /// is added or removed, so the override has to run again on every change.
  private func applyTitlebarChromeOverrides(to window: NSWindow) {
    window.titlebarSeparatorStyle = .none
    window.titlebarAppearsTransparent = true
  }

  private func tabbingMode(for preference: SessionWindowTabbingPreference) -> NSWindow.TabbingMode {
    switch preference {
    case .system:
      .automatic
    case .always:
      .preferred
    case .never:
      .disallowed
    }
  }
}
