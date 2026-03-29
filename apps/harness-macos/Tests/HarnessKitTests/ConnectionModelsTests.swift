import Foundation
import Testing

@testable import HarnessKit

@Suite("Connection models")
struct ConnectionModelsTests {
  @Test("ConnectionQuality thresholds map correctly")
  func qualityThresholds() {
    #expect(ConnectionQuality(latencyMs: nil) == .disconnected)
    #expect(ConnectionQuality(latencyMs: 10) == .excellent)
    #expect(ConnectionQuality(latencyMs: 49) == .excellent)
    #expect(ConnectionQuality(latencyMs: 50) == .good)
    #expect(ConnectionQuality(latencyMs: 149) == .good)
    #expect(ConnectionQuality(latencyMs: 150) == .degraded)
    #expect(ConnectionQuality(latencyMs: 499) == .degraded)
    #expect(ConnectionQuality(latencyMs: 500) == .poor)
    #expect(ConnectionQuality(latencyMs: 5000) == .poor)
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
    let before = Date()
    let event = ConnectionEvent(
      kind: .connected,
      detail: "test",
      transportKind: .webSocket
    )
    let after = Date()
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
