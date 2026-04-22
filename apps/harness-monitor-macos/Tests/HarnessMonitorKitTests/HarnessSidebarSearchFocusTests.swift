import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Sidebar search focused value Equatable contract")
struct HarnessSidebarSearchFocusTests {

  @Test("values with same dispatcher and availability are equal")
  func valuesWithSameDispatcherAndAvailabilityAreEqual() {
    let dispatcher = HarnessSidebarSearchFocusDispatcher()

    let first = HarnessSidebarSearchFocus(isAvailable: true, dispatcher: dispatcher)
    let second = HarnessSidebarSearchFocus(isAvailable: true, dispatcher: dispatcher)

    #expect(first == second)
  }

  @Test("differing availability compares as unequal")
  func differingAvailabilityComparesAsUnequal() {
    let dispatcher = HarnessSidebarSearchFocusDispatcher()

    let available = HarnessSidebarSearchFocus(isAvailable: true, dispatcher: dispatcher)
    let unavailable = HarnessSidebarSearchFocus(isAvailable: false, dispatcher: dispatcher)

    #expect(available != unavailable)
  }

  @Test("differing dispatcher references compare as unequal")
  func differingDispatcherReferencesCompareAsUnequal() {
    let first = HarnessSidebarSearchFocus(
      isAvailable: true,
      dispatcher: HarnessSidebarSearchFocusDispatcher()
    )
    let second = HarnessSidebarSearchFocus(
      isAvailable: true,
      dispatcher: HarnessSidebarSearchFocusDispatcher()
    )

    #expect(first != second)
  }

  @Test("invoke forwards to dispatcher handler")
  func invokeForwardsToDispatcherHandler() {
    let dispatcher = HarnessSidebarSearchFocusDispatcher()
    var callCount = 0
    dispatcher.handler = { callCount += 1 }

    let focus = HarnessSidebarSearchFocus(isAvailable: true, dispatcher: dispatcher)
    focus.invoke()
    focus.invoke()

    #expect(callCount == 2)
  }

  @Test("invoke does nothing when unavailable")
  func invokeDoesNothingWhenUnavailable() {
    let dispatcher = HarnessSidebarSearchFocusDispatcher()
    var callCount = 0
    dispatcher.handler = { callCount += 1 }

    let focus = HarnessSidebarSearchFocus(isAvailable: false, dispatcher: dispatcher)
    focus.invoke()

    #expect(callCount == 0)
  }
}
