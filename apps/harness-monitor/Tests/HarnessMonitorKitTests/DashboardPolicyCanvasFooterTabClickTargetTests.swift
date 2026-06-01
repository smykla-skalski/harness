import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard policy canvas footer tab click target")
@MainActor
struct DashboardPolicyCanvasFooterTabClickTargetTests {
  @Test("single click selects immediately")
  func singleClickSelectsImmediately() {
    var singleClicks = 0
    var doubleClicks = 0
    let coordinator = DashboardPolicyCanvasFooterTabClickTarget.Coordinator(
      onHover: { _ in },
      singleClick: { singleClicks += 1 },
      doubleClick: { doubleClicks += 1 }
    )

    coordinator.handleClick(count: 1)

    #expect(singleClicks == 1)
    #expect(doubleClicks == 0)
  }

  @Test("double click keeps immediate selection and starts rename")
  func doubleClickKeepsImmediateSelectionAndStartsRename() {
    var singleClicks = 0
    var doubleClicks = 0
    let coordinator = DashboardPolicyCanvasFooterTabClickTarget.Coordinator(
      onHover: { _ in },
      singleClick: { singleClicks += 1 },
      doubleClick: { doubleClicks += 1 }
    )

    coordinator.handleClick(count: 1)
    coordinator.handleClick(count: 2)

    #expect(singleClicks == 1)
    #expect(doubleClicks == 1)
  }
}
