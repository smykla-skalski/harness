import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability export")
struct HarnessMonitorObservabilityExportTests {
  @Test("HTTP/protobuf shutdown exports traces, logs, and metrics")
  func httpProtobufShutdownExportsAllSignals() async throws {
    OTLPAndTimelineURLProtocol.reset()
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
      OTLPAndTimelineURLProtocol.reset()
    }

    let temporaryHome = try temporaryDirectory()
    let environment = HarnessMonitorEnvironment(
      values: [
        "HARNESS_OTEL_EXPORT": "1",
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
      ],
      homeDirectory: temporaryHome
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OTLPAndTimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.setHTTPExporterSessionForTests(session)
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let entries = try await client.timeline(sessionID: "observability-export", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(entries.count == 1)
    #expect(
      try await OTLPAndTimelineURLProtocol.waitForExportPaths(
        ["/v1/traces", "/v1/logs", "/v1/metrics"],
        timeout: 2
      )
    )
  }
}

@Suite("Harness Monitor observability smoke")
struct HarnessMonitorObservabilitySmokeTests {
  @Test("Collector-configured shutdown flushes signals for the smoke lane")
  func collectorConfiguredShutdownFlushesSignalsForSmoke() async throws {
    guard ProcessInfo.processInfo.environment["HARNESS_MONITOR_OTEL_SMOKE"] == "1" else {
      return
    }

    OTLPAndTimelineURLProtocol.reset()
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
      OTLPAndTimelineURLProtocol.reset()
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OTLPAndTimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.setHTTPExporterSessionForTests(session)
    let entries = try await client.timeline(sessionID: "observability-smoke", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(entries.count == 1)
  }
}

private final class OTLPAndTimelineURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var exportPaths = Set<String>()

  override static func canInit(with request: URLRequest) -> Bool {
    guard let url = request.url else {
      return false
    }

    if url.host == "127.0.0.1" && url.port == 4318 {
      return true
    }

    return url.host == "127.0.0.1" && url.port == 9999
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    if requestURL.port == 4318 {
      _ = Self.lock.withLock {
        Self.exportPaths.insert(requestURL.path)
      }

      guard
        let response = HTTPURLResponse(
          url: requestURL,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }

      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    let responseBody =
      """
      [
        {
          "entry_id": "entry-1",
          "recorded_at": "2026-04-14T03:00:00Z",
          "kind": "tool_result",
          "session_id": "observability-export",
          "agent_id": null,
          "task_id": null,
          "summary": "Summary entry",
          "payload": {}
        }
      ]
      """
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    lock.withLock {
      exportPaths.removeAll()
    }
  }

  static func waitForExportPaths(
    _ expectedPaths: Set<String>,
    timeout: TimeInterval
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if lock.withLock({ expectedPaths.isSubset(of: exportPaths) }) {
        return true
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    return lock.withLock { expectedPaths.isSubset(of: exportPaths) }
  }
}

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
