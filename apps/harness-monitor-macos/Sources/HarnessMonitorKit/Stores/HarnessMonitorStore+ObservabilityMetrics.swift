import Foundation

extension HarnessMonitorStore {
  func startResourceMetricsSampling() {
    resourceMetricsSampler.startSampling()
    recordStoreActivityMetrics()
  }

  func stopResourceMetricsSampling() {
    resourceMetricsSampler.stopSampling()
  }

  func recordStoreActivityMetrics() {
    recordActiveTaskGauge()
    recordWebSocketConnectionGauge()
  }

  func recordActiveTaskGauge() {
    HarnessMonitorTelemetry.shared.recordActiveTasks(sessionIndex.totalOpenWorkCount)
  }

  func recordWebSocketConnectionGauge() {
    let connectionCount = activeTransport == .webSocket && connectionState == .online ? 1 : 0
    HarnessMonitorTelemetry.shared.recordWebSocketConnections(connectionCount)
  }
}
