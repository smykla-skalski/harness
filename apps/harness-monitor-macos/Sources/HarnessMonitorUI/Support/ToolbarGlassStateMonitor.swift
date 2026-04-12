import AppKit
import SwiftUI

public struct ToolbarGlassReproConfiguration: Sendable {
  private static let forceInstantFocusRingKey = "HARNESS_MONITOR_FORCE_INSTANT_FOCUS_RING"
  private static let disableContentDetailChromeKey = "HARNESS_MONITOR_DISABLE_CONTENT_DETAIL_CHROME"
  private static let disableToolbarBaselineOverlayKey =
    "HARNESS_MONITOR_DISABLE_TOOLBAR_BASELINE_OVERLAY"
  private static let disablePreferredColorSchemeKey =
    "HARNESS_MONITOR_DISABLE_PREFERRED_COLOR_SCHEME"

  public static let current = Self()

  public let usesInstantFocusRing: Bool
  public let disablesContentDetailChrome: Bool
  public let disablesToolbarBaselineOverlay: Bool
  public let disablesPreferredColorScheme: Bool

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    usesInstantFocusRing = environment[Self.forceInstantFocusRingKey] == "1"
    disablesContentDetailChrome = environment[Self.disableContentDetailChromeKey] == "1"
    disablesToolbarBaselineOverlay = environment[Self.disableToolbarBaselineOverlayKey] == "1"
    disablesPreferredColorScheme = environment[Self.disablePreferredColorSchemeKey] == "1"
  }
}

// NSWindow draws a titlebar/toolbar separator at the AppKit level, above all
// SwiftUI content. On macOS 26 with Liquid Glass the NavigationSplitView
// sidebar is translucent glass, so that line bleeds through the sidebar area
// even though ToolbarBaselineOverlay only draws in the detail column (starting
// at the sidebar's right edge). Setting titlebarSeparatorStyle to .none makes
// the custom overlay the sole separator, correctly scoped to the detail column.
// NSToolbar.showsBaselineSeparator was deprecated in macOS 15 - titlebarSeparatorStyle
// is the replacement (available since macOS 12).
//
// The NSView subclass uses viewDidMoveToWindow() instead of DispatchQueue.main.async
// because makeNSView is called before SwiftUI inserts the view into the window
// hierarchy. The async dispatch fires while window is still nil and the call
// silently no-ops. viewDidMoveToWindow() is the guaranteed AppKit callback that
// fires with a non-nil window.
private final class _TitlebarSeparatorSuppressorView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.titlebarSeparatorStyle = .none
  }
}

private struct ToolbarBaselineSeparatorSuppressor: NSViewRepresentable {
  func makeNSView(context: Context) -> _TitlebarSeparatorSuppressorView {
    _TitlebarSeparatorSuppressorView()
  }

  func updateNSView(_ nsView: _TitlebarSeparatorSuppressorView, context: Context) {
    nsView.window?.titlebarSeparatorStyle = .none
  }
}

extension View {
  func suppressToolbarBaselineSeparator() -> some View {
    background(ToolbarBaselineSeparatorSuppressor())
  }
}

struct OptionalToolbarBaselineOverlayModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.toolbarBaselineOverlay()
    } else {
      content
    }
  }
}
