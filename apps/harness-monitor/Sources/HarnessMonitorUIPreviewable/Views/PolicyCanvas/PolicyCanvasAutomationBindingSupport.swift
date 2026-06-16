import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

extension PolicyGraphAutomationBinding {
  static func defaultPreprocessors(
    for source: AutomationPolicyEventSource
  ) -> [AutomationPolicyPreprocessor] {
    switch source {
    case .clipboard:
      [
        .respectPasteboardPrivacy,
        .skipSensitiveMarkers,
        .filterSourceApplications,
        .dedupeByFingerprint,
      ]
    case .manualReviewTextPaste:
      [.normalizeGitHubPullRequestLinks, .dedupePullRequests]
    case .reviewScreenshotPaste:
      [.dedupeByFingerprint, .normalizeGitHubPullRequestLinks, .dedupePullRequests]
    case .manualOCRPaste, .ocrDrop, .ocrFilePicker, .screenshotFolder:
      [.dedupeByFingerprint]
    }
  }
}

func selectedOrderedValues<Value>(
  _ allValues: [Value],
  selectedRawValues: [String]
) -> [Value] where Value: RawRepresentable, Value.RawValue == String {
  let selected = Set(selectedRawValues)
  return allValues.filter { selected.contains($0.rawValue) }
}

func orderedValues<Value>(
  _ allValues: [Value],
  selectedRawValues: [String],
  fallback: [Value]
) -> [Value] where Value: RawRepresentable, Value.RawValue == String, Value: Equatable {
  let selected = Set(selectedRawValues)
  let values = allValues.filter { selected.contains($0.rawValue) }
  return values.isEmpty ? fallback : values
}

func toggledRawValues(
  _ rawValues: [String],
  rawValue: String,
  enabled: Bool
) -> [String] {
  var values = rawValues.filter { !$0.isEmpty }
  if enabled {
    if !values.contains(rawValue) {
      values.append(rawValue)
    }
    return values
  }
  return values.filter { $0 != rawValue }
}
