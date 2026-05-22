import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("DependencyRefreshTracker")
struct DependencyRefreshTrackerTests {
  @Test("default state has nothing in flight")
  func defaultStateIsEmpty() {
    let tracker = DependencyRefreshTracker()
    #expect(!tracker.isRefreshing("pr-1"))
    #expect(tracker.actionTitle(for: "pr-1") == nil)
  }

  @Test("begin then end clears the entry")
  func beginEndRoundTripClears() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    #expect(tracker.isRefreshing("pr-1"))
    #expect(tracker.actionTitle(for: "pr-1") == "Approving")

    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(!tracker.isRefreshing("pr-1"))
    #expect(tracker.actionTitle(for: "pr-1") == nil)
  }

  @Test("overlapping begins keep the row lit until every end completes")
  func overlappingBeginsRefCount() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    #expect(tracker.isRefreshing("pr-1"))

    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(tracker.isRefreshing("pr-1"), "one outstanding begin still active")

    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(!tracker.isRefreshing("pr-1"))
  }

  @Test("duplicate ids inside a single begin increment by the duplicate count")
  func duplicateIDsInSingleCallStack() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1", "pr-1"], actionTitle: "Merging")
    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(tracker.isRefreshing("pr-1"), "second increment still in flight")

    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(!tracker.isRefreshing("pr-1"))
  }

  @Test("empty arrays are no-ops on both ends")
  func emptyArrayIsNoOp() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: [], actionTitle: "Approving")
    #expect(tracker.counts.isEmpty)
    #expect(tracker.actionTitles.isEmpty)

    tracker.end(pullRequestIDs: [])
    #expect(tracker.counts.isEmpty)
  }

  @Test("end without prior begin removes nothing and does not go negative")
  func endWithoutBeginIsSafe() {
    var tracker = DependencyRefreshTracker()
    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(!tracker.isRefreshing("pr-1"))
    #expect(tracker.counts["pr-1"] == nil, "no negative bookkeeping")
  }

  @Test("action title from the later begin overwrites the earlier one")
  func laterTitleOverwrites() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Merging")
    #expect(tracker.actionTitle(for: "pr-1") == "Merging")
  }

  @Test("begin without a title leaves the existing title in place")
  func untitledBeginPreservesTitle() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: nil)
    #expect(tracker.actionTitle(for: "pr-1") == "Approving")
  }

  @Test("multiple pull requests track independently")
  func multiplePullRequestsTrackIndependently() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1", "pr-2"], actionTitle: "Labeling")
    #expect(tracker.isRefreshing("pr-1"))
    #expect(tracker.isRefreshing("pr-2"))
    #expect(tracker.actionTitle(for: "pr-1") == "Labeling")
    #expect(tracker.actionTitle(for: "pr-2") == "Labeling")

    tracker.end(pullRequestIDs: ["pr-1"])
    #expect(!tracker.isRefreshing("pr-1"))
    #expect(tracker.isRefreshing("pr-2"), "pr-2 unaffected by pr-1's end")
  }

  @Test("prune drops entries for pull requests no longer in the catalog")
  func pruneDropsMissingIDs() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.begin(pullRequestIDs: ["pr-2"], actionTitle: "Merging")
    tracker.prune(toLiveIDs: ["pr-1"])
    #expect(tracker.isRefreshing("pr-1"))
    #expect(!tracker.isRefreshing("pr-2"), "pr-2 was not in the live set")
    #expect(tracker.actionTitle(for: "pr-2") == nil)
  }

  @Test("prune keeps live ids untouched including their action titles")
  func prunePreservesLiveEntries() {
    var tracker = DependencyRefreshTracker()
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.begin(pullRequestIDs: ["pr-1"], actionTitle: "Approving")
    tracker.prune(toLiveIDs: ["pr-1", "pr-3"])
    #expect(tracker.isRefreshing("pr-1"))
    #expect(tracker.actionTitle(for: "pr-1") == "Approving")
    #expect(tracker.counts["pr-1"] == 2, "ref count preserved across prune")
  }
}
