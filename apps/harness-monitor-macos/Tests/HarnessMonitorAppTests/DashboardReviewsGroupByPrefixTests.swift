import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
struct DashboardReviewsGroupByPrefixTests {
  private func label(_ name: String) -> ReviewRepositoryLabel {
    ReviewRepositoryLabel(name: name, color: nil, description: nil)
  }

  @Test("empty input yields no groups")
  func emptyInputYieldsNoGroups() {
    let groups = dashboardReviewsGroupByPrefix([])
    #expect(groups.isEmpty)
  }

  @Test("labels with no slash live in a single leading group")
  func unprefixedLabelsCollapseIntoOneGroup() {
    let groups = dashboardReviewsGroupByPrefix([
      label("bug"),
      label("dependencies"),
      label("enhancement"),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].map(\.name) == ["bug", "dependencies", "enhancement"])
  }

  @Test("prefixed labels split into per-prefix groups in alphabetical order")
  func prefixedLabelsSplitByPrefix() {
    let groups = dashboardReviewsGroupByPrefix([
      label("ci/auto-merge"),
      label("ci/revert"),
      label("kind/bug"),
      label("kind/feature"),
      label("triage/accepted"),
      label("triage/pending"),
    ])
    #expect(groups.count == 3)
    #expect(groups[0].map(\.name) == ["ci/auto-merge", "ci/revert"])
    #expect(groups[1].map(\.name) == ["kind/bug", "kind/feature"])
    #expect(groups[2].map(\.name) == ["triage/accepted", "triage/pending"])
  }

  @Test("unprefixed labels lead, prefix groups follow alphabetically")
  func mixedLabelsPlaceUnprefixedFirst() {
    let groups = dashboardReviewsGroupByPrefix([
      label("bug"),
      label("ci/auto-merge"),
      label("ci/revert"),
      label("dependencies"),
      label("enhancement"),
      label("kind/bug"),
      label("triage/accepted"),
    ])
    #expect(groups.count == 4)
    #expect(groups[0].map(\.name) == ["bug", "dependencies", "enhancement"])
    #expect(groups[1].map(\.name) == ["ci/auto-merge", "ci/revert"])
    #expect(groups[2].map(\.name) == ["kind/bug"])
    #expect(groups[3].map(\.name) == ["triage/accepted"])
  }

  @Test("labels starting with slash are treated as unprefixed")
  func leadingSlashLabelsAreUnprefixed() {
    let groups = dashboardReviewsGroupByPrefix([
      label("/odd"),
      label("kind/bug"),
    ])
    #expect(groups.count == 2)
    #expect(groups[0].map(\.name) == ["/odd"])
    #expect(groups[1].map(\.name) == ["kind/bug"])
  }

  @Test("labels with multiple slashes group by the first segment")
  func nestedSlashesUseFirstSegment() {
    let groups = dashboardReviewsGroupByPrefix([
      label("area/api/auth"),
      label("area/frontend/web"),
      label("kind/bug"),
    ])
    #expect(groups.count == 2)
    #expect(groups[0].map(\.name) == ["area/api/auth", "area/frontend/web"])
    #expect(groups[1].map(\.name) == ["kind/bug"])
  }
}
