import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability smoke", .serialized)
struct HarnessMonitorObservabilitySmokeTests {
  @Test("Collector-configured shutdown flushes signals for the smoke lane")
  func collectorConfiguredShutdownFlushesSignalsForSmoke() async throws {
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
      TimelineURLProtocol.reset()
    }

    let environment = try smokeEnvironment()
    guard
      let config = try HarnessMonitorObservabilityConfig.resolve(using: environment),
      config.monitorSmokeEnabled
    else {
      return
    }
    #expect(config.source == .sharedFile)
    #expect(config.transport == .grpc)
    #expect(config.grpcEndpoint?.absoluteString == "http://127.0.0.1:4317")
    #expect(config.monitorSmokeEnabled)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let modelContainer = try HarnessMonitorModelContainer.live(using: environment)
    let cacheService = SessionCacheService(
      modelContainer: modelContainer,
      databaseURL: HarnessMonitorPaths.harnessRoot(using: environment)
        .appendingPathComponent("harness-cache.store")
    )
    let cacheCounts = await cacheService.recordCounts()
    let entries = try await client.timeline(sessionID: "observability-smoke", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(cacheCounts.sessions == 0)
    #expect(entries.count == 1)
  }

  @Test("Collector-configured smoke emits real daemon websocket spans")
  func collectorConfiguredSmokeEmitsRealDaemonWebSocketSpans() async throws {
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let smokeEnv = try smokeEnvironment()
    let resolvedSmokeConfig = try HarnessMonitorObservabilityConfig.resolve(using: smokeEnv)
    guard let smokeConfig = resolvedSmokeConfig, smokeConfig.monitorSmokeEnabled else {
      return
    }

    let temporaryHome = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    let xdgDataHome = temporaryHome.appendingPathComponent("xdg-data", isDirectory: true)
    let daemonDataHome = temporaryHome.appendingPathComponent("daemon-data", isDirectory: true)
    try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: daemonDataHome, withIntermediateDirectories: true)
    try writeSharedConfig(homeDirectory: xdgDataHome, grpcEndpoint: "http://127.0.0.1:4317")

    let environment = HarnessMonitorEnvironment(
      values: [
        "XDG_DATA_HOME": xdgDataHome.path,
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonDataHome.path,
      ],
      homeDirectory: temporaryHome
    )
    let daemon = try await LiveDaemonFixture.start(
      xdgDataHome: xdgDataHome,
      daemonDataHome: daemonDataHome,
      environmentOverrides: liveCollectorEnvironmentOverrides(from: smokeConfig)
    )
    defer {
      Task {
        await daemon.stop()
      }
    }

    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let transport = WebSocketTransport(connection: daemon.connection)
    try await transport.connect()
    _ = try await transport.sessions()
    await transport.shutdown()
    HarnessMonitorTelemetry.shared.shutdown()
    // Keep the test host alive long enough for the live collector/Tempo path
    // to observe the flushed websocket client span before xctest tears down.
    try await Task.sleep(for: .seconds(2))
  }
}

final class TimelineURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1" && request.url?.port == 9999
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
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

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let body = timelineResponseBody(sessionID: "observability-smoke")
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {}
}

final class OTLPAndTimelineURLProtocol: URLProtocol, @unchecked Sendable {
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

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let body = timelineResponseBody(sessionID: "observability-export")
    client?.urlProtocol(self, didLoad: Data(body.utf8))
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

func timelineResponseBody(sessionID: String) -> String {
  """
  [
    {
      "entry_id": "entry-1",
      "recorded_at": "2026-04-14T03:00:00Z",
      "kind": "tool_result",
      "session_id": "\(sessionID)",
      "agent_id": null,
      "task_id": null,
      "summary": "Summary entry",
      "payload": {}
    }
  ]
  """
}
