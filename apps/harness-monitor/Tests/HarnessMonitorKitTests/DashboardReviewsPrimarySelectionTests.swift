import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews primary selection resolver")
struct DashboardReviewsPrimarySelectionTests {
  @Test("single new selection becomes the primary, not the lexical min")
  func singleNewSelectionBecomesPrimary() {
    // User had nothing selected, then clicked "zzz". "zzz" sorts last
    // lexically, so the old `newValue.min()` rule would have lost the click.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: [],
      newSelection: ["zzz"],
      currentPrimary: ""
    )
    #expect(result == "zzz")
  }

  @Test("single new addition to an existing selection becomes the primary")
  func singleAdditionToExistingSelectionBecomesPrimary() {
    // User had ["aaa"] selected; cmd-clicks "zzz". The lexical-min rule
    // would have kept "aaa" as primary even though the user clearly intended
    // the new click to drive the detail pane.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa"],
      newSelection: ["aaa", "zzz"],
      currentPrimary: "aaa"
    )
    #expect(result == "zzz")
  }

  @Test("select-all (multi-add in one delta) falls back to lexical first")
  func selectAllFallsBackToLexicalFirst() {
    // No persisted primary, user hits select-all. Stable behavior is to pick
    // the lexical first so the detail pane has something deterministic to
    // show.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: [],
      newSelection: ["bbb", "aaa", "ccc"],
      currentPrimary: ""
    )
    #expect(result == "aaa")
  }

  @Test("deselecting the primary picks the next-best from the survivors")
  func deselectingPrimaryPicksNextBest() {
    // User had ["aaa", "bbb", "ccc"] with "ccc" as primary, then cmd-clicks
    // "ccc" to deselect it. delta is empty, primary is no longer in the
    // selection, so fall back to lexical first of the survivors.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa", "bbb", "ccc"],
      newSelection: ["aaa", "bbb"],
      currentPrimary: "ccc"
    )
    #expect(result == "aaa")
  }

  @Test("deselecting a non-primary leaves the primary unchanged")
  func deselectingNonPrimaryLeavesPrimaryUnchanged() {
    // User has ["aaa", "bbb", "ccc"] with "ccc" as primary, then cmd-clicks
    // "aaa" to deselect it. The primary is still in newSelection, so it
    // must stick. (The buggy `newValue.min()` would have flipped to "bbb".)
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa", "bbb", "ccc"],
      newSelection: ["bbb", "ccc"],
      currentPrimary: "ccc"
    )
    #expect(result == "ccc")
  }

  @Test("empty selection keeps the persisted primary intact")
  func emptySelectionKeepsPersistedPrimary() {
    // Clearing all rows should not wipe the persisted primary - that value
    // is what drives the detail pane to keep showing the "last seen" PR
    // when the user momentarily deselects everything.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa", "bbb"],
      newSelection: [],
      currentPrimary: "bbb"
    )
    #expect(result == "bbb")
  }

  @Test("no-op selection change keeps the current primary")
  func noOpSelectionChangeKeepsPrimary() {
    // SwiftUI sometimes redelivers identical Set values via onChange. The
    // helper should be a no-op for those.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa", "bbb"],
      newSelection: ["aaa", "bbb"],
      currentPrimary: "bbb"
    )
    #expect(result == "bbb")
  }

  @Test("primary not in new selection and no additions falls back to lexical min")
  func staleNonMemberPrimaryFallsBackToLexicalMin() {
    // The persisted primary might be a stale value from a previous session
    // that is not in the current selection at all. With no additions and
    // no survivor, fall back to the lexical first.
    let result = DashboardReviewsPrimarySelectionResolver.resolve(
      oldSelection: ["aaa", "bbb"],
      newSelection: ["aaa"],
      currentPrimary: "ccc"
    )
    #expect(result == "aaa")
  }
}
