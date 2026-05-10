import AppKit

public enum SessionWindowTabbingSupport {
  public static let tabbingIdentifier = "io.harnessmonitor.session"

  static func tabbingMode(for preference: SessionWindowTabbingPreference) -> NSWindow.TabbingMode {
    switch preference {
    case .system:
      .automatic
    case .always:
      .preferred
    case .never:
      .disallowed
    }
  }

  public static func shouldPreferTabbedOpen(
    preference: SessionWindowTabbingPreference,
    userPreference: NSWindow.UserTabbingPreference,
    targetIsFullScreen: Bool
  ) -> Bool {
    switch preference {
    case .always:
      return true
    case .never:
      return false
    case .system:
      switch userPreference {
      case .always:
        return true
      case .manual:
        return false
      case .inFullScreen:
        return targetIsFullScreen
      @unknown default:
        return false
      }
    }
  }

  @MainActor
  public static func shouldPreferTabbedOpen(
    preference: SessionWindowTabbingPreference,
    targetIsFullScreen: Bool
  ) -> Bool {
    shouldPreferTabbedOpen(
      preference: preference,
      userPreference: NSWindow.userTabbingPreference,
      targetIsFullScreen: targetIsFullScreen
    )
  }

  @MainActor
  public static func prepareSessionWindowForTabbing(
    _ window: NSWindow,
    preference: SessionWindowTabbingPreference
  ) {
    window.tabbingIdentifier = tabbingIdentifier
    window.tabbingMode = tabbingMode(for: preference)
  }

  @MainActor
  public static func visibleSessionTabTargetWindow(
    preference: SessionWindowTabbingPreference
  ) -> NSWindow? {
    guard
      let window = NSApplication.shared.orderedWindows.first(where: {
        $0.isVisible && !$0.isMiniaturized && $0.tabbingIdentifier == tabbingIdentifier
      })
    else {
      return nil
    }
    guard
      shouldPreferTabbedOpen(
        preference: preference,
        targetIsFullScreen: window.styleMask.contains(.fullScreen)
      )
    else {
      return nil
    }
    return window
  }
}
