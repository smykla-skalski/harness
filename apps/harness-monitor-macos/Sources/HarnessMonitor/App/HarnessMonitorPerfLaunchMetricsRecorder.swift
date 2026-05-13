import Foundation
import HarnessMonitorKit

struct HarnessMonitorPerfLaunchMetricSample: Codable, Equatable {
  let appInitToReadyMilliseconds: Double
  let measuredFrom: String
  let stateLabel: String
  let windowID: String
  let includesBootstrapInScenarioMeasurement: Bool

  enum CodingKeys: String, CodingKey {
    case appInitToReadyMilliseconds = "app_init_to_ready_ms"
    case measuredFrom = "measured_from"
    case stateLabel = "state_label"
    case windowID = "window_id"
    case includesBootstrapInScenarioMeasurement = "includes_bootstrap_in_scenario_measurement"
  }
}

@MainActor
final class HarnessMonitorPerfLaunchMetricsRecorder {
  static let environmentKey = "HARNESS_MONITOR_PERF_LAUNCH_METRICS_PATH"
  private static let measurementOrigin = "app_init"
  private static let shared = HarnessMonitorPerfLaunchMetricsRecorder(
    outputPath: ProcessInfo.processInfo.environment[environmentKey],
    startSystemUptime: ProcessInfo.processInfo.systemUptime
  )

  private let outputPath: String?
  private let startSystemUptime: TimeInterval
  private var hasWritten = false

  static func bootstrap() {
    _ = shared
  }

  init(
    outputPath: String?,
    startSystemUptime: TimeInterval
  ) {
    self.outputPath = outputPath?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.startSystemUptime = startSystemUptime
  }

  static func recordScenarioReady(
    windowID: String,
    stateLabel: String,
    includesBootstrapInScenarioMeasurement: Bool
  ) {
    shared.recordScenarioReady(
      windowID: windowID,
      stateLabel: stateLabel,
      includesBootstrapInScenarioMeasurement: includesBootstrapInScenarioMeasurement
    )
  }

  func recordScenarioReady(
    windowID: String,
    stateLabel: String,
    includesBootstrapInScenarioMeasurement: Bool,
    currentSystemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    guard let outputPath, !outputPath.isEmpty else {
      return
    }
    guard !hasWritten else {
      return
    }
    hasWritten = true

    let elapsedMilliseconds = max(currentSystemUptime - startSystemUptime, 0) * 1_000
    let sample = HarnessMonitorPerfLaunchMetricSample(
      appInitToReadyMilliseconds: elapsedMilliseconds,
      measuredFrom: Self.measurementOrigin,
      stateLabel: stateLabel,
      windowID: windowID,
      includesBootstrapInScenarioMeasurement: includesBootstrapInScenarioMeasurement
    )

    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(sample)
      let url = URL(fileURLWithPath: outputPath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url, options: .atomic)
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to write perf launch metrics to \(outputPath, privacy: .public): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }
}
