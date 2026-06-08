import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Performance guard for the crossing-aware orthogonal nudge - now the production
/// route post-process default. The pass runs inside the synchronous route worker;
/// if it is slow the canvas is stuck waiting for the first final route result. The
/// pass must stay free on small graphs and, on the fan-in heavy samples whose cold
/// A* routing already dominates the frame, within a small multiple of plain
/// collinear compression (the cheaper post-process that leaves overlaps stacked).
/// The bound is relative, not an absolute millisecond budget, so it rides out the
/// machine load and parallel-build contention that make raw wall-clock timings
/// jump run to run.
@Suite("Policy canvas orthogonal nudge route performance", .serialized)
@MainActor
struct PolicyCanvasOrthogonalNudgeRoutePerformanceTests {
  /// The included samples' crossing-aware route worker may take at most this
  /// multiple of the same graph's collinear (overlap-leaving) route worker. The
  /// original per-placement global rescore was ~28x; local scoring plus band
  /// pruning keeps it well under this.
  private static let maximumBaselineRatio = 3.0
  /// Graphs whose collinear routing is faster than this are too quick to time
  /// reliably - a ratio taken off a sub-millisecond baseline is pure scheduler
  /// noise - so they are recorded in the table but not gated.
  private static let measurableBaselineMilliseconds: Double = 5
  /// The largest stress fixtures remain covered by correctness tests, but are
  /// too expensive for the routine relative-overhead performance guard.
  private static let excludedStressSampleIDs: Set<String> = [
    "extreme-matrix",
    "extreme-mesh",
    "extreme-lattice",
    "extreme-galaxy",
  ]

  private static var performanceSampleIDs: [String] {
    PolicyCanvasLabSamples.all.map(\.id).filter { !excludedStressSampleIDs.contains($0) }
  }

  @Test("performance sample set skips only the four largest stress samples")
  func performanceSampleSetSkipsOnlyLargestStressSamples() {
    let allSampleIDs = PolicyCanvasLabSamples.all.map(\.id)

    #expect(Self.excludedStressSampleIDs.count == 4)
    #expect(Self.excludedStressSampleIDs.isSubset(of: Set(allSampleIDs)))
    #expect(Self.performanceSampleIDs == allSampleIDs.filter {
      !Self.excludedStressSampleIDs.contains($0)
    })
    #expect(!Self.performanceSampleIDs.contains {
      Self.excludedStressSampleIDs.contains($0)
    })
    #expect(Self.performanceSampleIDs.contains("extreme"))
    #expect(Self.performanceSampleIDs.contains("extreme-braid"))
  }

  @Test("crossing-aware routing stays within a small multiple of collinear")
  func postProcessOverheadStaysModest() async throws {
    let baseline = selection(PolicyCanvasAlgorithmDefaults.collinearRouteCompression)
    let nudged = selection(PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing)
    await warmUp(selections: [baseline, nudged])
    var table = "sample: collinear / nudge (ms)  x-collinear\n"
    var worstRatio = 0.0
    var worstSample = ""
    for sampleID in Self.performanceSampleIDs {
      let prepared = try await preparedInput(sampleID: sampleID)
      let baselineMs = await measure { _ = await PolicyCanvasRouteWorker().compute(input: prepared(baseline)) }
      let nudgeMs = await measure { _ = await PolicyCanvasRouteWorker().compute(input: prepared(nudged)) }
      let ratio = baselineMs >= Self.measurableBaselineMilliseconds ? nudgeMs / baselineMs : 1
      table += "\(sampleID): \(ms(baselineMs)) / \(ms(nudgeMs))  \(ratioText(ratio))\n"
      if ratio > worstRatio {
        worstRatio = ratio
        worstSample = sampleID
      }
    }
    #expect(
      worstRatio < Self.maximumBaselineRatio,
      "crossing-aware routing hit \(ratioText(worstRatio)) collinear on \(worstSample)\n\(table)"
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
