import Foundation
import HarnessMonitorKit

extension TaskBoardAutomationInspectorPresentationWorker {
  static func timestampRow(
    _ id: String,
    _ label: String,
    _ timestamp: String?,
    _ referenceDate: Date
  ) -> TaskBoardAutomationValueRow {
    guard let timestamp else { return valueRow(id, label, "Not scheduled") }
    return TaskBoardAutomationValueRow(
      id: id,
      label: label,
      value: relativeTimestamp(timestamp, referenceDate: referenceDate),
      accessibilityValue: timestamp,
      tone: .neutral
    )
  }

  static func valueRow(
    _ id: String,
    _ label: String,
    _ value: String,
    tone: TaskBoardAutomationTone = .neutral
  ) -> TaskBoardAutomationValueRow {
    TaskBoardAutomationValueRow(id: id, label: label, value: value, tone: tone)
  }

  static func relativeTimestamp(
    _ timestamp: String,
    referenceDate: Date
  ) -> String {
    guard let date = parseTimestamp(timestamp) else { return timestamp }
    let delta = date.timeIntervalSince(referenceDate)
    let magnitude = abs(delta)
    let value: String
    if magnitude < 60 {
      return delta > 0 ? "in <1m" : "just now"
    } else if magnitude < 3_600 {
      value = "\(Int(magnitude / 60))m"
    } else if magnitude < 86_400 {
      value = "\(Int(magnitude / 3_600))h"
    } else {
      value = "\(Int(magnitude / 86_400))d"
    }
    return delta > 0 ? "in \(value)" : "\(value) ago"
  }

  static func parseTimestamp(_ value: String) -> Date? {
    TaskBoardAutomationTimestampParser.parse(value)
  }

  static func scopeTitle(_ scope: TaskBoardAutomationScope) -> String {
    var components: [String] = []
    if let itemID = scope.itemId { components.append(itemID) }
    if let provider = scope.provider { components.append(title(provider.rawValue)) }
    if let providerScope = scope.providerScope { components.append(providerScope) }
    if let repository = scope.repository { components.append(repository) }
    if let status = scope.status { components.append(title(status.rawValue)) }
    return components.isEmpty ? "All eligible items" : components.joined(separator: " · ")
  }

  static func runStateTitle(_ run: TaskBoardAutomationRunInfo) -> String {
    run.outcome.map { title($0.rawValue) } ?? title(run.state.rawValue)
  }

  static func title(_ rawValue: String) -> String {
    rawValue.replacingOccurrences(of: "_", with: " ").capitalized
  }

  static func effectiveStateTone(
    _ state: TaskBoardAutomationEffectiveState
  ) -> TaskBoardAutomationTone {
    switch state {
    case .running:
      .success
    case .scheduled:
      .accent
    case .backingOff, .stopping:
      .warning
    case .degraded, .offline:
      .danger
    case .idle:
      .neutral
    }
  }

  static func desiredModeTone(
    _ mode: TaskBoardAutomationDesiredMode
  ) -> TaskBoardAutomationTone {
    switch mode {
    case .continuous:
      .success
    case .step:
      .warning
    case .off:
      .neutral
    }
  }

  static func admissionStateTone(
    _ state: TaskBoardAutomationAdmissionState
  ) -> TaskBoardAutomationTone {
    switch state {
    case .accepting:
      .success
    case .draining:
      .warning
    case .stopped:
      .neutral
    }
  }

  static func runTone(
    _ run: TaskBoardAutomationRunInfo
  ) -> TaskBoardAutomationTone {
    if let outcome = run.outcome {
      switch outcome {
      case .completed:
        return .success
      case .noop:
        return .neutral
      case .partial:
        return .warning
      case .failed, .cancelled:
        return .danger
      }
    }
    switch run.state {
    case .running:
      return .accent
    case .cancelling:
      return .warning
    case .terminal:
      return .neutral
    }
  }

  static func stageTone(_ state: String) -> TaskBoardAutomationTone {
    switch state.lowercased() {
    case "completed", "succeeded", "success":
      .success
    case "failed", "error", "cancelled":
      .danger
    case "blocked", "retrying", "cancelling":
      .warning
    case "running", "active", "started":
      .accent
    default:
      .neutral
    }
  }
}

private enum TaskBoardAutomationTimestampParser {
  private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let standard = Date.ISO8601FormatStyle()

  static func parse(_ value: String) -> Date? {
    (try? fractional.parse(value)) ?? (try? standard.parse(value))
  }
}
