import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

enum HarnessMonitorUITestEnvironment {
  static let environmentKey = "HARNESS_MONITOR_UI_TESTS"
  static let hostBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  static let isHostBundle = Bundle.main.bundleIdentifier == hostBundleIdentifier
  static let isEnabled =
    ProcessInfo.processInfo.environment[environmentKey] == "1" || isHostBundle
  static let accessibilityMarkersEnabled: Bool = {
    guard isEnabled else {
      return false
    }
    return ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_ACCESSIBILITY_MARKERS"] != "0"
  }()
  static let generalMarkersEnabled = accessibilityMarkersEnabled
}

enum HarnessMonitorAccessibilityLiveRegion {
  case polite
  case assertive
}

private struct AccessibilityFrameMarker: View {
  let identifier: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityIdentifier(identifier)
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessMonitorUITestEnvironment.generalMarkersEnabled {
      content.overlay {
        AccessibilityFrameMarker(identifier: identifier)
      }
    } else {
      content
    }
  }
}

extension View {
  func accessibilityLiveRegion(
    _ region: HarnessMonitorAccessibilityLiveRegion
  ) -> some View {
    speechAnnouncementsQueued(region == .polite)
  }

  func accessibilityFrameMarker(_ identifier: String) -> some View {
    modifier(AccessibilityFrameMarkerModifier(identifier: identifier))
  }
}
