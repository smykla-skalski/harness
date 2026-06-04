import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Performance guard for the crossing-aware route post-process (Path A). The pass
/// runs inside the synchronous route worker; if it is slow the canvas shows the
/// provisional projection first and then visibly snaps to the final routing once
/// the worker returns. The pass must stay free on small graphs and, on the fan-in
/// heavy samples whose cold A* routing already dominates the frame, within a small
/// multiple of the production-default (collinear) routing. The bound is relative,
/// not an absolute millisecond budget, so it rides out the machine load and
/// parallel-build contention that make raw wall-clock timings jump run to run.
@Suite("Policy canvas Claude crossing-aware route performance", .serialized)
@MainActor
struct PolicyCanvasClaudeCrossingAwareRoutePerformanceTests {
  /// The heaviest sample's crossing-aware route worker may take at most this
  /// multiple of the same graph's default (collinear) route worker. The original
  /// per-placement global rescore was ~28x the default; local scoring plus band
  /// pruning keeps it well under this.
  private static let maximumBaselineRatio = 3.0
  /// Graphs whose default routing is faster than this are too quick to time
  /// reliably - a ratio taken off a sub-millisecond baseline is pure scheduler
  /// noise - so they are recorded in the table but not gated.
  private static let measurableBaselineMilliseconds: Double = 5

  @Test("crossing-aware routing stays within a small multiple of the default")
  func postProcessOverheadStaysModest() async throws {
    let baseline = selection(PolicyCanvasAlgorithmDefaults.collinearRouteCompression)
    let nudged = selection(PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing)
    let claude = selection(PolicyCanvasAlgorithmDefaults.claudeCrossingAwareRouteProcessing)
    await warmUp(selections: [baseline, nudged, claude])
    var table = "sample: baseline / nudge / claude (ms)  x-default\n"
    var worstRatio = 0.0
    var worstSample = ""
    for sampleID in PolicyCanvasLabSamples.all.map(\.id) {
      let prepared = try await preparedInput(sampleID: sampleID)
      let baselineMs = await measure { _ = await PolicyCanvasRouteWorker().compute(input: prepared(baseline)) }
      let nudgeMs = await measure { _ = await PolicyCanvasRouteWorker().compute(input: prepared(nudged)) }
      let claudeMs = await measure { _ = await PolicyCanvasRouteWorker().compute(input: prepared(claude)) }
      let ratio = baselineMs >= Self.measurableBaselineMilliseconds ? claudeMs / baselineMs : 1
      table += "\(sampleID): \(ms(baselineMs)) / \(ms(nudgeMs)) / \(ms(claudeMs))  \(ratioText(ratio))\n"
      if ratio > worstRatio {
        worstRatio = ratio
        worstSample = sampleID
      }
    }
    #expect(
      worstRatio < Self.maximumBaselineRatio,
      "crossing-aware routing hit \(ratioText(worstRatio)) the default on \(worstSample)\n\(table)"
    )
  }

  // MARK: - Harness

  private func selection(
    _ id: PolicyCanvasAlgorithmID
  ) -> PolicyCanvasAlgorithmSelection {
    PolicyCanvasAlgorithmSelection.referenceRouting.replacing(stage: .routePostProcessing, with: id)
  }

  /// Route every selection once, discarded, so the first timed sample is not
  /// charged for one-time process warm-up the later samples never pay - the bias
  /// that otherwise makes the cold first measurement (the baseline) read high.
  private func warmUp(selections: [PolicyCanvasAlgorithmSelection]) async {
    guard let prepared = try? await preparedInput(sampleID: "default") else {
      return
    }
    for selection in selections {
      _ = await PolicyCanvasRouteWorker().compute(input: prepared(selection))
    }
  }

  /// Minimum of three runs to discard scheduling noise; each run gets a fresh
  /// worker so the input-equality cache never short-circuits the compute.
  private func measure(_ body: () async -> Void) async -> Double {
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<3 {
      let start = Date()
      await body()
      best = min(best, Date().timeIntervalSince(start) * 1000)
    }
    return best
  }

  private func ms(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  private func ratioText(_ value: Double) -> String {
    String(format: "%.2fx", value)
  }

  /// Load a sample, lay it out once, and return a builder that stamps a routing
  /// selection onto the frozen layout so every preset routes the same graph.
  private func preparedInput(
    sampleID: String
  ) async throws -> (PolicyCanvasAlgorithmSelection) -> PolicyCanvasRouteWorkerInput {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let nodes = viewModel.nodes
    let groups = viewModel.groups
    let edges = viewModel.edges
    let routingHints = viewModel.routingHints
    return { selection in
      PolicyCanvasRouteWorkerInput(
        nodes: nodes,
        groups: groups,
        edges: edges,
        fontScale: 1,
        routingHints: routingHints,
        algorithmSelection: selection
      )
    }
  }
}
