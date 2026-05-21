// swiftlint:disable file_length
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
    1_024: 130_000_000,
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

  @Test("ACP event presentation worker matches synchronous materialization")
  func acpEventPresentationWorkerMatchesSynchronousMaterialization() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-worker"
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-worker",
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
    let payload = Self.makePayload(batchSize: 8, rawCount: 10)
    let recordedAt = "2026-04-28T00:00:01Z"
    let expectedEntries = payload.timelineEntries(
      fallbackRecordedAt: recordedAt,
      toolCallMetadata: store.acpToolCallTimelineMetadata(for: payload)
    )

    let output = await store.acpRuntimeWorker.eventPresentation(
      input: AcpEventPresentationInput(
        payload: payload,
        recordedAt: recordedAt,
        selectedSessionID: store.selectedSessionID,
        descriptorsByID: store.acpAgentDescriptorsByID,
        sessionRegistrations: store.selectedSession?.agents ?? [],
        snapshots: store.selectedAcpAgents,
        inspectSample: store.selectedAcpInspectState
      )
    )

    #expect(output.entries == expectedEntries)
    #expect(output.liveToolCallRowIDs.count == 8)
    #expect(output.overflowNotice?.rawUpdateCount == 10)
    #expect(output.overflowNotice?.displayedEventCount == 8)
  }

  @Test("ACP inspect replacement worker prepares missing runtime state")
  func acpInspectReplacementWorkerPreparesMissingRuntimeState() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let activeAgent = makeAcpSnapshot(
      acpID: "acp-1",
      sessionID: "sess-acp-worker",
      agentID: "worker",
      displayName: "Worker",
      pendingBatches: []
    )

    let output = await store.acpRuntimeWorker.inspectReplacement(
      response: AcpAgentInspectResponse(
        agents: [],
        available: false,
        issueMessage: "ACP inspect unavailable."
      ),
      sessionID: "sess-acp-worker",
      sampledAt: Date(timeIntervalSince1970: 15),
      activeAgents: [activeAgent],
      currentSyncEntries: [:]
    )

    let identity = AcpRuntimeIdentity(snapshot: activeAgent)
    #expect(output.sample.agents.isEmpty)
    #expect(output.syncEntries[identity]?.phase == .unavailable)
    #expect(output.syncEntries[identity]?.message == "ACP inspect unavailable.")
    #expect(!output.hasRecoverableMissingEntries)
  }

  @Test("ACP agent state worker matches synchronous apply")
  func acpAgentStateWorkerMatchesSynchronousApply() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-worker"
    let previous = makeAcpSnapshot(
      acpID: "acp-old",
      sessionID: "sess-acp-worker",
      agentID: "worker",
      displayName: "Worker",
      pendingBatches: []
    )
    let incoming = makeAcpSnapshot(
      acpID: "acp-new",
      sessionID: "sess-acp-worker",
      agentID: "worker",
      displayName: "Worker",
      pendingBatches: []
    )
    let staleBatch = makeAcpPermissionBatch(
      batchID: "batch-stale",
      acpID: "acp-old",
      sessionID: "sess-acp-worker",
      createdAt: "2026-04-28T00:00:01Z"
    )
    let pendingBatch = makeAcpPermissionBatch(
      batchID: "batch-pending",
      acpID: "acp-new",
      sessionID: "sess-acp-worker",
      createdAt: "2026-04-28T00:00:02Z"
    )
    store.selectedAcpAgents = [previous]
    store.standaloneAcpPermissionBatches = [staleBatch, pendingBatch]

    let output = await store.acpRuntimeWorker.agentUpdate(
      snapshot: incoming,
      currentAgents: store.selectedAcpAgents,
      standalonePermissionBatches: store.standaloneAcpPermissionBatches,
      currentInspectSample: store.selectedAcpInspectState,
      currentInspectSyncEntries: store.selectedAcpInspectSyncEntries
    )
    store.applyAcpAgent(incoming)

    #expect(output.selectedAgents == store.selectedAcpAgents)
    #expect(output.standalonePermissionBatches == store.standaloneAcpPermissionBatches)
    #expect(output.selectedAgents.first?.pendingPermissionBatches == [pendingBatch])
    #expect(output.staleRestartDecisionIDs == ["acp-permission:batch-stale"])
  }

  @Test("ACP agents replacement worker matches synchronous reconcile")
  func acpAgentsReplacementWorkerMatchesSynchronousReconcile() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-worker"
    let pendingBatch = makeAcpPermissionBatch(
      batchID: "batch-alpha",
      acpID: "acp-alpha",
      sessionID: "sess-acp-worker",
      createdAt: "2026-04-28T00:00:02Z"
    )
    let payload = AcpAgentsReconciledPayload(
      sessionId: "sess-acp-worker",
      agents: [
        makeAcpSnapshot(
          acpID: "acp-zeta",
          sessionID: "sess-acp-worker",
          agentID: "zeta-agent",
          displayName: "Zeta",
          pendingBatches: []
        ),
        makeAcpSnapshot(
          acpID: "acp-alpha",
          sessionID: "sess-acp-worker",
          agentID: "alpha-agent",
          displayName: "Alpha",
          pendingBatches: []
        ),
      ],
      inspect: AcpAgentInspectResponse(
        agents: [
          makeAcpInspectSnapshot(
            acpID: "acp-zeta",
            sessionID: "sess-acp-worker",
            agentID: "zeta-agent",
            displayName: "Zeta"
          ),
          makeAcpInspectSnapshot(
            acpID: "acp-alpha",
            sessionID: "sess-acp-worker",
            agentID: "alpha-agent",
            displayName: "Alpha"
          ),
        ],
        available: true,
        issueMessage: nil
      )
    )
    let sampledAt = Date(timeIntervalSince1970: 42)
    store.standaloneAcpPermissionBatches = [pendingBatch]

    let output = await store.acpRuntimeWorker.agentsReplacement(
      payload: payload,
      sampledAt: sampledAt,
      standalonePermissionBatches: store.standaloneAcpPermissionBatches,
      currentInspectSample: store.selectedAcpInspectState,
      currentInspectSyncEntries: store.selectedAcpInspectSyncEntries
    )
    store.replaceAcpAgents(payload, sampledAt: sampledAt)

    #expect(output.selectedAgents == store.selectedAcpAgents)
    #expect(output.standalonePermissionBatches == store.standaloneAcpPermissionBatches)
    #expect(output.inspectSample == store.selectedAcpInspectState)
    #expect(output.inspectSyncEntries == store.selectedAcpInspectSyncEntries)
    #expect(output.selectedAgents.map(\.displayName) == ["Alpha", "Zeta"])
    #expect(output.selectedAgents.first?.pendingPermissionBatches == [pendingBatch])
  }

  @Test("ACP permission batch worker matches synchronous apply and removal")
  func acpPermissionBatchWorkerMatchesSynchronousApplyAndRemoval() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-acp-worker"
    let agent = makeAcpSnapshot(
      acpID: "acp-1",
      sessionID: "sess-acp-worker",
      agentID: "worker",
      displayName: "Worker",
      pendingBatches: []
    )
    let batch = makeAcpPermissionBatch(
      batchID: "batch-1",
      acpID: "acp-1",
      sessionID: "sess-acp-worker",
      createdAt: "2026-04-28T00:00:01Z"
    )
    store.selectedAcpAgents = [agent]

    let applyOutput = await store.acpRuntimeWorker.permissionBatchApply(
      batch: batch,
      currentAgents: store.selectedAcpAgents,
      standalonePermissionBatches: store.standaloneAcpPermissionBatches
    )
    store.applyAcpPermissionBatch(batch)

    #expect(applyOutput.selectedAgents == store.selectedAcpAgents)
    #expect(applyOutput.standalonePermissionBatches == store.standaloneAcpPermissionBatches)

    let removalOutput = await store.acpRuntimeWorker.permissionBatchRemoval(
      batch: batch,
      currentAgents: store.selectedAcpAgents,
      standalonePermissionBatches: store.standaloneAcpPermissionBatches
    )
    store.removeAcpPermissionBatch(batch)

    #expect(removalOutput.selectedAgents == store.selectedAcpAgents)
    #expect(removalOutput.standalonePermissionBatches == store.standaloneAcpPermissionBatches)
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

    let payload = Self.makePayload(batchSize: batchSize, rawCount: batchSize)

    let clock = ContinuousClock()
    let start = clock.now
    store.applyAcpEvents(payload, recordedAt: "2026-04-28T00:00:01Z")
    return nanoseconds(for: start.duration(to: clock.now))
  }

  private static func makePayload(batchSize: Int, rawCount: Int) -> AcpEventBatchPayload {
    AcpEventBatchPayload(
      acpId: "acp-1",
      sessionId: "sess-acp-perf",
      rawCount: rawCount,
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
