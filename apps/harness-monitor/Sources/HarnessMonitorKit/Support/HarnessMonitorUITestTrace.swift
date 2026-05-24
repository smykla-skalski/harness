import Foundation

private struct HarnessMonitorUITestTraceRecord: Codable {
  let timestamp: String
  let component: String
  let event: String
  let details: [String: String]
}

public enum HarnessMonitorUITestTrace {
  private static let uiArtifactsDirectoryKey = "HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR"
  public static let perfArtifactsDirectoryKey = "HARNESS_MONITOR_PERF_ARTIFACTS_DIR"
  private static let fileName = "app-trace.jsonl"
  private static let preservedDirectoryName = "HarnessMonitorUITestPreservedArtifacts"
  private static let writeQueue = DispatchQueue(
    label: "io.harnessmonitor.uitrace.write",
    qos: .utility
  )
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()
  public static var isEnabled: Bool {
    hasArtifactsDirectory(for: uiArtifactsDirectoryKey)
  }

  public static var isPerfEnabled: Bool {
    hasArtifactsDirectory(for: perfArtifactsDirectoryKey)
  }

  public static func record(
    component: String,
    event: String,
    details: [String: String] = [:]
  ) {
    record(
      component: component,
      event: event,
      details: details,
      artifactsDirectoryKey: uiArtifactsDirectoryKey,
      includePreservedTrace: true
    )
  }

  public static func recordPerf(
    component: String,
    event: String,
    details: [String: String] = [:]
  ) {
    record(
      component: component,
      event: event,
      details: details,
      artifactsDirectoryKey: perfArtifactsDirectoryKey,
      includePreservedTrace: false
    )
  }

  private static func record(
    component: String,
    event: String,
    details: [String: String],
    artifactsDirectoryKey: String,
    includePreservedTrace: Bool
  ) {
    let fileURLs = traceFileURLs(
      artifactsDirectoryKey: artifactsDirectoryKey,
      includePreservedTrace: includePreservedTrace
    )
    guard !fileURLs.isEmpty else {
      return
    }
    let record = HarnessMonitorUITestTraceRecord(
      timestamp: timestamp(),
      component: component,
      event: event,
      details: details
    )
    guard let data = try? encoder.encode(record) else {
      return
    }

    writeQueue.async {
      for fileURL in fileURLs {
        do {
          try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          if FileManager.default.fileExists(atPath: fileURL.path) == false {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
          }
          let handle = try FileHandle(forWritingTo: fileURL)
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
          try handle.write(contentsOf: Data([0x0A]))
          try handle.close()
        } catch {
          continue
        }
      }
    }
  }

  private static func traceFileURLs(
    artifactsDirectoryKey: String,
    includePreservedTrace: Bool
  ) -> [URL] {
    var urls: [URL] = []
    if let traceURL = traceURL(for: artifactsDirectoryKey) {
      urls.append(traceURL)
    }
    guard includePreservedTrace else { return urls }
    urls.append(
      FileManager.default.temporaryDirectory
        .appendingPathComponent(preservedDirectoryName, isDirectory: true)
        .appendingPathComponent(preservedTraceFileName)
    )
    return urls
  }

  private static func traceURL(for artifactsDirectoryKey: String) -> URL? {
    guard
      let artifactsDirectory = ProcessInfo.processInfo.environment[artifactsDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      artifactsDirectory.isEmpty == false
    else {
      return nil
    }
    return URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
      .appendingPathComponent(fileName)
  }

  private static func hasArtifactsDirectory(for artifactsDirectoryKey: String) -> Bool {
    guard
      let artifactsDirectory = ProcessInfo.processInfo.environment[artifactsDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return false
    }
    return artifactsDirectory.isEmpty == false
  }

  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
  }

  private static var preservedTraceFileName: String {
    let bundleIdentifier = (Bundle.main.bundleIdentifier ?? "harnessmonitor")
      .replacingOccurrences(of: ".", with: "-")
    return "\(bundleIdentifier)-\(ProcessInfo.processInfo.processIdentifier)-\(fileName)"
  }
}

extension HarnessMonitorStore.PendingConfirmation {
  public var uiTestTraceLabel: String {
    switch self {
    case .endSession:
      "end-session"
    case .removeSession:
      "remove-session"
    case .removeSessions:
      "remove-sessions"
    case .deleteTask:
      "delete-task"
    case .deleteTasks:
      "delete-tasks"
    case .removeAgent:
      "remove-agent"
    case .removeAgents:
      "remove-agents"
    case .interruptCodexRun:
      "interrupt-codex-run"
    }
  }
}
