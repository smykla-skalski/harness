import CoreGraphics
import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Regression gates and the deterministic dump for the graph-quality report,
/// run against every lab sample through the real routing pipeline.
@MainActor
struct PolicyCanvasGraphQualityGateTests {
  /// Route a lab sample exactly the way the lab renders it (load -> reflow ->
  /// route worker) and measure the resulting graph.
  func routedReport(sampleID: String) async throws -> PolicyCanvasGraphQualityReport {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      algorithmSelection: .referenceRouting
    )
    let output = await PolicyCanvasRouteWorker().compute(input: input)
    return policyCanvasMeasureGraphQuality(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: output.routes
    )
  }

  /// Per-sample regression gate across every lab sample: each gated category must
  /// stay at or below its budget. Budgets are today's measured values, so any
  /// layout or routing change that makes a sample worse fails here; improvements
  /// just leave headroom (drop the budget once a lower count is banked). A sample
  /// with no budget entry gets all-zero budgets and fails until its baseline is
  /// captured.
  ///
  /// This loops every sample inside one test rather than using a parametrized
  /// `@Test(arguments:)`: parametrized swift-testing cases are not matched by the
  /// `-only-testing` selector the build runs with, so a parametrized gate is
  /// silently skipped. `#expect` records each violation independently and keeps
  /// going, so a single run still reports every offending (sample, category) pair.
  @Test func allSamplesStayWithinBudget() async throws {
    for sample in PolicyCanvasLabSamples.all {
      let report = try await routedReport(sampleID: sample.id)
      for category in PolicyCanvasQualityCategory.allCases where category.isGated {
        let actual = report.count(for: category)
        let budget = PolicyCanvasGraphQualityBudgets.limit(category, forSampleID: sample.id)
        #expect(
          actual <= budget,
          "\(sample.id): \(category.label) = \(actual) exceeds budget \(budget)"
        )
      }
    }
  }

  /// Deterministic dump of every sample's report to
  /// `tmp/policy-canvas/graph-quality-baseline.txt` (resolved from `#filePath`,
  /// matching the fan-in dump convention). Captures the baseline used to set the
  /// per-sample gate budgets and serves as the standing graph-quality snapshot.
  @Test func dumpAllSampleReports() async throws {
    var lines: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let report = try await routedReport(sampleID: sample.id)
      lines.append("## \(sample.id) (\(sample.name))")
      for headline in report.headlines {
        lines.append("  \(headline.label): \(headline.value)")
      }
      lines.append("  max edge length: \(Int(report.edgeLengths.maxLength.rounded()))")
      lines.append("  total bends: \(report.edgeLengths.totalBends)")
      lines.append("  occupancy: \(String(format: "%.3f", report.bounds.nodeOccupancyRatio))")
      lines.append("")
    }
    writeReport(lines.joined(separator: "\n"), name: "graph-quality-baseline.txt")
    #expect(!PolicyCanvasLabSamples.all.isEmpty)
  }

  private func writeReport(_ contents: String, name: String) {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let worktreeRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let directory = worktreeRoot.appendingPathComponent("tmp/policy-canvas")
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try? contents.write(
      to: directory.appendingPathComponent(name),
      atomically: true,
      encoding: .utf8
    )
  }
}
