import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("ACP event batch coalescing performance")
struct AcpEventBatchCoalesceTests {
  private static let batchSizes = [1, 32, 256, 1_024]
  private static let warmupSamples = 2
  private static let measuredSamples = 9
  private static let checkedInMedianBaselinesNs: [Int: UInt64] = [
    1: 5_000_000,
    32: 10_000_000,
    256: 30_000_000,
    1_024: 100_000_000,
  ]
  private static let regressionMultiplier = 2.0

  @Test("ACP apply batch stays within the checked-in regression envelope")
  func acpApplyBatchStaysWithinTheCheckedInRegressionEnvelope() {
    let measurements = Dictionary(
      uniqueKeysWithValues: Self.batchSizes.map { batchSize in
        (
          batchSize,
          measureApplyAcpEvents(
            batchSize: batchSize,
            warmupSamples: Self.warmupSamples,
            measuredSamples: Self.measuredSamples
          )
        )
      }
    )

    for batchSize in Self.batchSizes {
      guard
        let measurement = measurements[batchSize],
        let baseline = Self.checkedInMedianBaselinesNs[batchSize]
      else {
        Issue.record("Missing ACP performance baseline or measurement for batch \(batchSize)")
        return
      }
      let budget = UInt64(Double(baseline) * Self.regressionMultiplier)
      #expect(
        measurement.medianNanoseconds <= budget,
        """
        ACP applyAcpEvents median for batch \(batchSize) was \(measurement.medianNanoseconds)ns, \
        exceeding the \(budget)ns budget. Histogram: \(measurement.histogramDescription)
        """
      )
    }

    guard let burstMeasurement = measurements[1_024] else {
      Issue.record("Missing ACP burst performance measurement")
      return
    }
    #expect(
      burstMeasurement.histogram.totalSamples == Self.measuredSamples,
      "Burst histogram lost samples: \(burstMeasurement.histogramDescription)"
    )
    #expect(!burstMeasurement.histogramDescription.isEmpty)
  }

  private func measureApplyAcpEvents(
    batchSize: Int,
    warmupSamples: Int,
    measuredSamples: Int
  ) -> BatchMeasurement {
    for _ in 0..<warmupSamples {
      _ = measureOneApply(batchSize: batchSize)
    }

    let samples = (0..<measuredSamples).map { _ in
      measureOneApply(batchSize: batchSize)
    }
    return BatchMeasurement(batchSize: batchSize, samplesNanoseconds: samples)
  }

  private func measureOneApply(batchSize: Int) -> UInt64 {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-perf"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-perf",
        pendingBatches: []
      )
    )
    store.acpAgentDescriptorsByID["copilot"] = AcpAgentDescriptor(
      id: "copilot",
      displayName: "Copilot",
      capabilities: ["filesystem", "terminal"],
      launchCommand: "copilot",
      launchArgs: [],
      envPassthrough: [],
      doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
    )

    let payload = AcpEventBatchPayload(
      acpId: "acp-1",
      sessionId: "sess-acp-perf",
      rawCount: batchSize,
      events: (0..<batchSize).map { index in
        AcpConversationEvent(
          timestamp: "2026-04-28T00:00:00Z",
          sequence: UInt64(index),
          kind: .object([
            "type": .string(index.isMultiple(of: 2) ? "tool_invocation" : "tool_result"),
            "tool_name": .string(index.isMultiple(of: 2) ? "Read" : "Write"),
            "invocation_id": .string("call-\(index)"),
          ]),
          agent: "copilot",
          sessionId: "sess-acp-perf"
        )
      }
    )

    let clock = ContinuousClock()
    let start = clock.now
    store.applyAcpEvents(payload, recordedAt: "2026-04-28T00:00:01Z")
    return nanoseconds(for: start.duration(to: clock.now))
  }

  private func nanoseconds(for duration: Duration) -> UInt64 {
    let seconds = UInt64(max(0, duration.components.seconds))
    let attoseconds = UInt64(max(0, duration.components.attoseconds))
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
  }
}

private struct BatchMeasurement {
  let batchSize: Int
  let samplesNanoseconds: [UInt64]

  var medianNanoseconds: UInt64 {
    let sorted = samplesNanoseconds.sorted()
    return sorted[sorted.count / 2]
  }

  var histogram: BatchMeasurementHistogram {
    BatchMeasurementHistogram(samplesNanoseconds: samplesNanoseconds)
  }

  var histogramDescription: String {
    histogram.description
  }
}

private struct BatchMeasurementHistogram {
  private static let buckets: [(label: String, upperBoundNanoseconds: UInt64)] = [
    ("<1ms", 1_000_000),
    ("1-2ms", 2_000_000),
    ("2-5ms", 5_000_000),
    ("5-10ms", 10_000_000),
    ("10-20ms", 20_000_000),
    ("20-50ms", 50_000_000),
  ]

  let bucketCounts: [(label: String, count: Int)]

  init(samplesNanoseconds: [UInt64]) {
    var counts = Self.buckets.map { (label: $0.label, count: 0) }
    var overflow = 0
    for sample in samplesNanoseconds {
      if let bucketIndex = Self.buckets.firstIndex(where: { sample < $0.upperBoundNanoseconds }) {
        counts[bucketIndex].count += 1
      } else {
        overflow += 1
      }
    }
    counts.append((label: "50ms+", count: overflow))
    bucketCounts = counts
  }

  var totalSamples: Int {
    bucketCounts.reduce(0) { $0 + $1.count }
  }

  var description: String {
    bucketCounts
      .compactMap { bucket -> String? in
        guard bucket.count >= 1 else {
          return nil
        }
        return "\(bucket.label)=\(bucket.count)"
      }
      .joined(separator: ", ")
  }
}
