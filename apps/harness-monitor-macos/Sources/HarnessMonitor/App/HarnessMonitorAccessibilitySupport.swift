import SwiftUI

enum HarnessMonitorUITestEnvironment {
  static let isEnabled = ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
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

private struct AccessibilityProbe: View {
  let identifier: String
  let label: String?
  let value: String?

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(label ?? "")
      .accessibilityValue(value ?? "")
      .accessibilityIdentifier(identifier)
  }
}

struct AccessibilityTextMarker: View {
  let identifier: String
  let text: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(text)
      .accessibilityIdentifier(identifier)
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessMonitorUITestEnvironment.isEnabled {
      content.overlay {
        AccessibilityFrameMarker(identifier: identifier)
      }
    } else {
      content
    }
  }
}

private struct AccessibilityProbeModifier: ViewModifier {
  let identifier: String
  let label: String?
  let value: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessMonitorUITestEnvironment.isEnabled {
      content.overlay {
        AccessibilityProbe(
          identifier: identifier,
          label: label,
          value: value
        )
      }
    } else {
      content
    }
  }
}

extension View {
  func accessibilityFrameMarker(_ identifier: String) -> some View {
    modifier(AccessibilityFrameMarkerModifier(identifier: identifier))
  }

  func accessibilityTestProbe(
    _ identifier: String,
    label: String? = nil,
    value: String? = nil
  ) -> some View {
    modifier(
      AccessibilityProbeModifier(
        identifier: identifier,
        label: label,
        value: value
      )
    )
  }

  @ViewBuilder
  func harnessUITestValue(_ value: String) -> some View {
    if HarnessMonitorUITestEnvironment.isEnabled {
      accessibilityValue(value)
    } else {
      self
    }
  }
}
