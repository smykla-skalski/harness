import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Connection models")
struct ConnectionModelsTests {
  @Test(
    "ConnectionQuality thresholds map correctly",
    arguments: [
      (nil, ConnectionQuality.disconnected),
      (0, ConnectionQuality.excellent),
      (10, ConnectionQuality.excellent),
      (49, ConnectionQuality.excellent),
      (50, ConnectionQuality.good),
      (149, ConnectionQuality.good),
      (150, ConnectionQuality.degraded),
      (499, ConnectionQuality.degraded),
      (500, ConnectionQuality.poor),
      (5000, ConnectionQuality.poor),
    ] as [(Int?, ConnectionQuality)]
  )
  func qualityThresholds(latencyMs: Int?, expected: ConnectionQuality) {
    #expect(ConnectionQuality(latencyMs: latencyMs) == expected)
  }

  @Test("ConnectionMetrics initial state has sensible defaults")
  func metricsInitial() {
    let metrics = ConnectionMetrics.initial
    #expect(metrics.transportKind == .httpSSE)
    #expect(metrics.latencyMs == nil)
    #expect(metrics.messagesReceived == 0)
    #expect(metrics.messagesSent == 0)
    #expect(metrics.reconnectCount == 0)
    #expect(metrics.isFallback == false)
    #expect(metrics.quality == .disconnected)
  }

  @Test("ConnectionMetrics quality derived from latency")
  func metricsQuality() {
    var metrics = ConnectionMetrics.initial
    metrics.latencyMs = 24
    #expect(metrics.quality == .excellent)
    metrics.latencyMs = 200
    #expect(metrics.quality == .degraded)
  }

  @Test("ConnectionEvent initializes with current timestamp")
  func eventInit() {
    let before = Date.now
    let event = ConnectionEvent(
      kind: .connected,
      detail: "test",
      transportKind: .webSocket
    )
    let after = Date.now
    #expect(event.kind == .connected)
    #expect(event.detail == "test")
    #expect(event.transportKind == .webSocket)
    #expect(event.timestamp >= before)
    #expect(event.timestamp <= after)
  }

  @Test("TransportKind raw values match expected strings")
  func transportKindRawValues() {
    #expect(TransportKind.webSocket.rawValue == "webSocket")
    #expect(TransportKind.httpSSE.rawValue == "httpSSE")
  }
}
