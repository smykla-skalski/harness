import Foundation

private struct HarnessMonitorUITestTraceRecord: Codable {
  let timestamp: String
  let component: String
  let event: String
  let details: [String: String]
}

public enum HarnessMonitorUITestTrace {
  private static let artifactsDirectoryKey = "HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR"
  private static let fileName = "app-trace.jsonl"
  private static let preservedDirectoryName = "HarnessMonitorUITestPreservedArtifacts"
  private static let lock = NSLock()
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  public static var isEnabled: Bool {
    guard
      let artifactsDirectory = ProcessInfo.processInfo.environment[artifactsDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      return false
    }
    return artifactsDirectory.isEmpty == false
  }

  public static func record(
    component: String,
    event: String,
    details: [String: String] = [:]
  ) {
    let fileURLs = traceFileURLs()
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

    lock.lock()
    defer { lock.unlock() }

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

  private static func traceFileURLs() -> [URL] {
    var urls: [URL] = []
    guard
      let artifactsDirectory = ProcessInfo.processInfo.environment[artifactsDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      artifactsDirectory.isEmpty == false
    else {
      return urls
    }
    urls.append(
      URL(fileURLWithPath: artifactsDirectory, isDirectory: true)
        .appendingPathComponent(fileName)
    )
    urls.append(
      FileManager.default.temporaryDirectory
        .appendingPathComponent(preservedDirectoryName, isDirectory: true)
        .appendingPathComponent(preservedTraceFileName)
    )
    return urls
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
    case .removeAgent:
      "remove-agent"
    case .interruptCodexRun:
      "interrupt-codex-run"
    }
  }
}
