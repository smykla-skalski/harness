import Foundation
import XCTest

struct HarnessMonitorUITestTraceEvent: Codable, Equatable {
  let timestamp: String
  let component: String
  let event: String
  let testName: String?
  let details: [String: String]
}

final class HarnessMonitorUITestTraceWriter {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let lock = NSLock()

  init(fileURL: URL) {
    self.fileURL = fileURL
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.sortedKeys]
  }

  func append(
    component: String,
    event: String,
    testName: String,
    details: [String: String] = [:]
  ) {
    let record = HarnessMonitorUITestTraceEvent(
      timestamp: Self.makeTimestamp(),
      component: component,
      event: event,
      testName: testName,
      details: details
    )

    guard let data = try? encoder.encode(record) else {
      return
    }

    lock.lock()
    defer { lock.unlock() }

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
      return
    }
  }

  private static func makeTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
  }
}

func diagnosticsTraceFileURL(for artifactsDirectoryKey: String) -> URL? {
  diagnosticsArtifactsDirectory(for: artifactsDirectoryKey)?
    .appendingPathComponent("ui-trace.jsonl")
}

func preservedDiagnosticsTraceFileURL() -> URL {
  let bundleIdentifier = (Bundle.main.bundleIdentifier ?? "harnessmonitor-uitests")
    .replacingOccurrences(of: ".", with: "-")
  return FileManager.default.temporaryDirectory
    .appendingPathComponent("HarnessMonitorUITestPreservedArtifacts", isDirectory: true)
    .appendingPathComponent(
      "\(bundleIdentifier)-\(ProcessInfo.processInfo.processIdentifier)-ui-trace.jsonl"
    )
}

func appTraceFileURL(for artifactsDirectoryKey: String) -> URL? {
  diagnosticsArtifactsDirectory(for: artifactsDirectoryKey)?
    .appendingPathComponent("app-trace.jsonl")
}

func preservedAppTraceFileURLs() -> [URL] {
  let preservedDirectory =
    FileManager.default.temporaryDirectory
    .appendingPathComponent("HarnessMonitorUITestPreservedArtifacts", isDirectory: true)
  guard
    let fileURLs = try? FileManager.default.contentsOfDirectory(
      at: preservedDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
  else {
    return []
  }

  return fileURLs
    .filter { $0.lastPathComponent.hasSuffix("-app-trace.jsonl") }
    .sorted { lhs, rhs in
      let lhsDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let rhsDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return lhsDate > rhsDate
    }
}

func appendDiagnosticsTrace(
  component: String,
  event: String,
  testName: String,
  details: [String: String] = [:],
  artifactsDirectoryKey: String
) {
  let fileURLs = [diagnosticsTraceFileURL(for: artifactsDirectoryKey), preservedDiagnosticsTraceFileURL()]
    .compactMap { $0 }
  guard !fileURLs.isEmpty else {
    return
  }
  for fileURL in fileURLs {
    HarnessMonitorUITestTraceWriter(fileURL: fileURL).append(
      component: component,
      event: event,
      testName: testName,
      details: details
    )
  }
}

extension HarnessMonitorUITestCase {
  func recordDiagnosticsTrace(
    component: String = "ui-test",
    event: String,
    app: XCUIApplication? = nil,
    details: [String: String] = [:]
  ) {
    var payload = details
    payload["test"] = name
    if let tracePath = diagnosticsTraceFileURL(for: Self.artifactsDirectoryKey)?.path {
      payload["trace_file"] = tracePath
    }
    if let app {
      payload["app_state"] = String(describing: app.state)
      let window = mainWindow(in: app)
      payload["main_window_exists"] = String(window.exists)
      if window.exists {
        if window.label.isEmpty == false {
          payload["main_window_label"] = window.label
        }
        payload["main_window_frame"] = frameSummary(window.frame)
      }
    }
    appendDiagnosticsTrace(
      component: component,
      event: event,
      testName: name,
      details: payload,
      artifactsDirectoryKey: Self.artifactsDirectoryKey
    )
  }

  func diagnosticsTracePath() -> String? {
    diagnosticsTraceFileURL(for: Self.artifactsDirectoryKey)?.path
  }

  func waitForAppTraceEvents(
    _ expectedEvents: [String],
    timeout: TimeInterval
  ) -> Bool {
    return waitUntil(timeout: timeout) {
      let candidateFiles =
        [appTraceFileURL(for: Self.artifactsDirectoryKey)].compactMap { $0 }
        + preservedAppTraceFileURLs()
      guard !candidateFiles.isEmpty else {
        return false
      }

      for fileURL in candidateFiles {
        guard let data = try? Data(contentsOf: fileURL),
          let contents = String(data: data, encoding: .utf8)
        else {
          continue
        }
        let events = contents
          .split(whereSeparator: \.isNewline)
          .compactMap(Self.decodeTraceEvent(from:))
          .map(\.event)
        if Self.containsSubsequence(expectedEvents, in: events) {
          return true
        }
      }
      return false
    }
  }

  private static func decodeTraceEvent(from line: Substring) -> HarnessMonitorUITestTraceEvent? {
    guard let data = String(line).data(using: .utf8) else {
      return nil
    }
    return try? JSONDecoder().decode(HarnessMonitorUITestTraceEvent.self, from: data)
  }

  private static func containsSubsequence(_ expected: [String], in actual: [String]) -> Bool {
    guard !expected.isEmpty else {
      return true
    }
    var nextIndex = 0
    for event in actual where event == expected[nextIndex] {
      nextIndex += 1
      if nextIndex == expected.count {
        return true
      }
    }
    return false
  }

  private func frameSummary(_ frame: CGRect) -> String {
    String(
      format: "x=%.1f y=%.1f w=%.1f h=%.1f",
      frame.origin.x,
      frame.origin.y,
      frame.size.width,
      frame.size.height
    )
  }
}
