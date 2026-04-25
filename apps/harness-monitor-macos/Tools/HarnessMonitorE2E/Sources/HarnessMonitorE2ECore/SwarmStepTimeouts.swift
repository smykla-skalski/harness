import Foundation

public enum SwarmStepTimeouts {
  public static let environmentKey = "HARNESS_MONITOR_SWARM_E2E_STEP_TIMEOUTS"
  public static let maxRecordingSecondsKey = "HARNESS_MONITOR_SWARM_E2E_MAX_RECORDING_SECONDS"
  public static let defaultTimeout: TimeInterval = 30
  public static let maxRecordingDuration: TimeInterval = 240

  private static let stepTimeouts: [String: TimeInterval] = [
    "act1": 45,
    "act2": 45,
    "act3": 25,
    "act4": 25,
    "act5": 30,
    "act6": 25,
    "act7": 25,
    "act8": 25,
    "act9": 25,
    "act10": 30,
    "act11": 20,
    "act12": 30,
    "act13": 25,
    "act14": 20,
    "act15": 20,
    "act16": 20,
  ]

  public static func timeout(for act: String) -> TimeInterval {
    stepTimeouts[act] ?? defaultTimeout
  }

  public static var encodedEnvironmentValue: String {
    let payload = stepTimeouts.reduce(into: [String: Double]()) { result, entry in
      result[entry.key] = entry.value
    }
    .merging(["default": defaultTimeout], uniquingKeysWith: { _, new in new })
    let data = try? JSONSerialization.data(
      withJSONObject: payload,
      options: [.sortedKeys]
    )
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? #"{"default":30}"#
  }

  public static func decodeEnvironment(_ rawValue: String) -> [String: TimeInterval]? {
    guard let data = rawValue.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    var decoded: [String: TimeInterval] = [:]
    for (key, value) in object {
      if let number = value as? NSNumber {
        decoded[key] = number.doubleValue
      }
    }
    return decoded.isEmpty ? nil : decoded
  }
}

struct RecordingDurationBudget {
  let maxDuration: TimeInterval?
  let pollInterval: TimeInterval

  func nextWaitInterval(startedAt: Date, now: Date) -> TimeInterval? {
    guard let maxDuration else {
      return pollInterval
    }

    let remaining = maxDuration - now.timeIntervalSince(startedAt)
    guard remaining > 0 else {
      return nil
    }
    return min(pollInterval, remaining)
  }
}
