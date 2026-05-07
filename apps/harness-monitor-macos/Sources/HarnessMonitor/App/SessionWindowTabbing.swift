import AppKit
import HarnessMonitorUIPreviewable
import os
import SwiftUI

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
    applyWindowTabbing()
  }

  func applyWindowTabbing() {
    guard let window else {
      return
    }
    if configuration.isSessionWindow {
      window.tabbingIdentifier = Self.sessionTabbingIdentifier
      window.tabbingMode = tabbingMode(for: configuration.preference)
    } else {
      window.tabbingIdentifier = ""
      window.tabbingMode = .disallowed
    }
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
