import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
struct DashboardReviewsPartitionFrequentTests {
  private func label(_ name: String) -> ReviewRepositoryLabel {
    ReviewRepositoryLabel(name: name, color: nil, description: nil)
  }

  @Test("partition with no frequent names returns everything in rest")
  func emptyFrequentNamesYieldsRestOnly() {
    let available = [label("a"), label("b"), label("c")]
    let split = dashboardReviewsPartitionFrequent(
      available: available,
      frequentNames: []
    )
    #expect(split.frequent.isEmpty)
    #expect(split.rest.map(\.name) == ["a", "b", "c"])
  }

  @Test("partition keeps frequent ordering and removes from rest")
  func frequentPreservesOrderAndStripsRest() {
    let available = [label("alpha"), label("beta"), label("gamma"), label("delta")]
    let split = dashboardReviewsPartitionFrequent(
      available: available,
      frequentNames: ["gamma", "alpha"]
    )
    #expect(split.frequent.map(\.name) == ["gamma", "alpha"])
    #expect(split.rest.map(\.name) == ["beta", "delta"])
  }

  @Test("partition skips frequent names missing from available")
  func unknownFrequentNamesAreDropped() {
    let available = [label("alpha"), label("beta")]
    let split = dashboardReviewsPartitionFrequent(
      available: available,
      frequentNames: ["zeta", "alpha", "omicron"]
    )
    #expect(split.frequent.map(\.name) == ["alpha"])
    #expect(split.rest.map(\.name) == ["beta"])
  }

  @Test("partition deduplicates repeated frequent names")
  func duplicateFrequentNamesAreDeduped() {
    let available = [label("alpha"), label("beta")]
    let split = dashboardReviewsPartitionFrequent(
      available: available,
      frequentNames: ["alpha", "alpha", "beta"]
    )
    #expect(split.frequent.map(\.name) == ["alpha", "beta"])
    #expect(split.rest.isEmpty)
  }
}
