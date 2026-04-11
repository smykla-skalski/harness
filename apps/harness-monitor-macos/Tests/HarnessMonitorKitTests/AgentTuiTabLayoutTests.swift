import CoreGraphics
import Testing

@testable import HarnessMonitorUI

@Suite("Agent TUI tab layout")
struct AgentTuiTabLayoutTests {
  @Test("Shows every recent session when width is ample")
  func showsAllSessionsWhenWidthIsAmple() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-3", "tui-2", "tui-1"],
      selectedSessionID: "tui-2",
      availableWidth: 920,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 140,
      overflowPickerWidth: 110
    )

    #expect(layout.visibleSessionIDs == ["tui-3", "tui-2", "tui-1"])
    #expect(layout.overflowSessionIDs.isEmpty)
  }

  @Test("Keeps the selected session visible when it would otherwise overflow")
  func keepsSelectedSessionVisible() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-5", "tui-4", "tui-3", "tui-2", "tui-1"],
      selectedSessionID: "tui-1",
      availableWidth: 560,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 140,
      overflowPickerWidth: 110
    )

    #expect(layout.visibleSessionIDs == ["tui-5", "tui-1"])
    #expect(layout.overflowSessionIDs == ["tui-4", "tui-3", "tui-2"])
  }

  @Test("Uses the real available width instead of the fallback width")
  func usesAvailableWidthForOverflowPartitioning() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-4", "tui-3", "tui-2", "tui-1"],
      selectedSessionID: "tui-4",
      availableWidth: 420,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 120,
      overflowPickerWidth: 110
    )

    #expect(layout.visibleSessionIDs == ["tui-4"])
    #expect(layout.overflowSessionIDs == ["tui-3", "tui-2", "tui-1"])
  }

  @Test("Deduplicates recent session ids while preserving MRU order")
  func deduplicatesRecentSessionIDs() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-3", "tui-2", "tui-3", "", "tui-1", "tui-2"],
      selectedSessionID: "tui-2",
      availableWidth: 920,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 140,
      overflowPickerWidth: 110
    )

    #expect(layout.visibleSessionIDs == ["tui-3", "tui-2", "tui-1"])
    #expect(layout.overflowSessionIDs.isEmpty)
  }

  @Test("Falls back to the default width before layout is measured")
  func fallsBackToDefaultWidthWhenGeometryIsNotReady() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-5", "tui-4", "tui-3", "tui-2", "tui-1"],
      selectedSessionID: "tui-2",
      availableWidth: 0,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 140,
      overflowPickerWidth: 110,
      fallbackWidth: 760
    )

    #expect(layout.visibleSessionIDs == ["tui-5", "tui-4", "tui-2"])
    #expect(layout.overflowSessionIDs == ["tui-3", "tui-1"])
  }

  @Test("Caps visible tabs at the sane session limit even on wide sheets")
  func capsVisibleTabsAtSaneSessionLimit() {
    let layout = AgentTuiTabLayout.make(
      recentSessionIDs: ["tui-6", "tui-5", "tui-4", "tui-3", "tui-2", "tui-1"],
      selectedSessionID: "tui-4",
      availableWidth: 1600,
      controlsWidth: 120,
      createTabWidth: 44,
      sessionTabMinimumWidth: 140,
      overflowPickerWidth: 110,
      maximumVisibleSessionTabs: 4
    )

    #expect(layout.visibleSessionIDs == ["tui-6", "tui-5", "tui-4", "tui-3"])
    #expect(layout.overflowSessionIDs == ["tui-2", "tui-1"])
  }
}
