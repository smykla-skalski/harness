import Foundation

extension HarnessMonitorStore {

  func applyLatency(
    _ latencyMs: Int,
    source: ConnectionLatencySource,
    to metrics: inout ConnectionMetrics
  ) {
    switch source {
    case .transport:
      metrics.transportLatencyMs = latencyMs
      metrics.averageTransportLatencyMs = appendLatencySample(
        latencyMs,
        to: &transportLatencySamplesMs
      )
    case .request:
      metrics.requestLatencyMs = latencyMs
      metrics.averageRequestLatencyMs = appendLatencySample(
        latencyMs,
        to: &requestLatencySamplesMs
      )
    }
  }

  func appendLatencySample(
    _ latencyMs: Int,
    to samples: inout [Int]
  ) -> Int {
    samples.append(latencyMs)
    if samples.count > Self.maxLatencySamples {
      samples.removeFirst(samples.count - Self.maxLatencySamples)
    }
    let total = samples.reduce(0, +)
    return total / max(samples.count, 1)
  }
}
