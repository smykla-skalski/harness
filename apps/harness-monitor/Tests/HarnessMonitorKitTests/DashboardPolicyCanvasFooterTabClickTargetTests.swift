import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard policy canvas footer tab click target")
@MainActor
struct DashboardPolicyCanvasFooterTabClickTargetTests {
  @Test("double click cancels the pending single click")
  func doubleClickCancelsPendingSingleClick() async throws {
    var singleClicks = 0
    var doubleClicks = 0
    let coordinator = DashboardPolicyCanvasFooterTabClickTarget.Coordinator(
      singleClickDelay: .milliseconds(20),
      onHover: { _ in },
      singleClick: { singleClicks += 1 },
      doubleClick: { doubleClicks += 1 }
    )

    coordinator.handleClick(count: 1)
    coordinator.handleClick(count: 2)
    try await Task.sleep(for: .milliseconds(40))

    #expect(singleClicks == 0)
    #expect(doubleClicks == 1)
  }

  @Test("single click fires after the double-click detection window")
  func singleClickFiresAfterDetectionWindow() async throws {
    var singleClicks = 0
    var doubleClicks = 0
    let coordinator = DashboardPolicyCanvasFooterTabClickTarget.Coordinator(
      singleClickDelay: .milliseconds(20),
      onHover: { _ in },
      singleClick: { singleClicks += 1 },
      doubleClick: { doubleClicks += 1 }
    )

    coordinator.handleClick(count: 1)
    try await Task.sleep(for: .milliseconds(40))

    #expect(singleClicks == 1)
    #expect(doubleClicks == 0)
  }
}
