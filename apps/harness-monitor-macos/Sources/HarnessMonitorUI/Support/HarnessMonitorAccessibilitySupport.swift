import SwiftUI

public enum HarnessMonitorUITestEnvironment {
  public static let environmentKey = "HARNESS_MONITOR_UI_TESTS"
  public static let perfScenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"
  public static let hostBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  public static let isHostBundle = Bundle.main.bundleIdentifier == hostBundleIdentifier
  public static let isEnabled =
    ProcessInfo.processInfo.environment[environmentKey] == "1" || isHostBundle
  public static let perfScenarioRawValue: String? = {
    guard isEnabled else {
      return nil
    }
    guard
      let rawScenario = ProcessInfo.processInfo.environment[perfScenarioEnvironmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawScenario.isEmpty
    else {
      return nil
    }
    return rawScenario
  }()
  public static let isPerfScenarioActive = perfScenarioRawValue != nil
  public static let accessibilityMarkersEnabled: Bool = {
    guard isEnabled else {
      return false
    }
    let environment = ProcessInfo.processInfo.environment
    return environment["HARNESS_MONITOR_UI_ACCESSIBILITY_MARKERS"] != "0"
  }()
  public static let generalMarkersEnabled =
    accessibilityMarkersEnabled && !isPerfScenarioActive
  public static let searchMarkersEnabled: Bool = {
    guard accessibilityMarkersEnabled else {
      return false
    }
    guard let perfScenarioRawValue else {
      return true
    }
    switch perfScenarioRawValue {
    case "refresh-and-search", "sidebar-overflow-search":
      return true
    default:
      return false
    }
  }()
  public static let selectionMarkersEnabled = generalMarkersEnabled
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

public struct AccessibilityTextMarker: View {
  let identifier: String
  let text: String

  public init(identifier: String, text: String) {
    self.identifier = identifier
    self.text = text
  }

  @ViewBuilder public var body: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      Color.clear
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(text)
        .accessibilityIdentifier(identifier)
    }
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
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
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
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
    if HarnessMonitorUITestEnvironment.generalMarkersEnabled {
      accessibilityValue(value)
    } else {
      self
    }
  }
}
