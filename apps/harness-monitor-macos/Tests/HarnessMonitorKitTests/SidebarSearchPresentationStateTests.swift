import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Sidebar search presentation state")
struct SidebarSearchPresentationStateTests {

  @Test("request defers while startup focus participation is disabled")
  func requestDefersWhileStartupFocusParticipationIsDisabled() {
    var state = SidebarSearchPresentationState()

    let didPresent = state.requestPresentation(canPresent: false)

    #expect(didPresent == false)
    #expect(state.isPresented == false)
    #expect(state.hasPendingFocusRequest == true)
  }

  @Test("pending request presents after startup focus participation is enabled")
  func pendingRequestPresentsAfterStartupFocusParticipationIsEnabled() {
    var state = SidebarSearchPresentationState()
    _ = state.requestPresentation(canPresent: false)

    let didPresent = state.applyPendingPresentationIfNeeded(canPresent: true)

    #expect(didPresent == true)
    #expect(state.isPresented == true)
    #expect(state.hasPendingFocusRequest == false)
  }

  @Test("request presents immediately when startup focus participation is enabled")
  func requestPresentsImmediatelyWhenStartupFocusParticipationIsEnabled() {
    var state = SidebarSearchPresentationState()

    let didPresent = state.requestPresentation(canPresent: true)

    #expect(didPresent == true)
    #expect(state.isPresented == true)
    #expect(state.hasPendingFocusRequest == false)
  }

  @MainActor
  @Test("filter visibility treats entered search text as active filtering")
  func filterVisibilityTreatsSearchTextAsActiveFilter() {
    let controls = HarnessMonitorStore.SessionControlsSlice()
    controls.searchText = "needs attention"

    let hasActiveFilters = SidebarFilterVisibilityPolicy.hasActiveFilters(in: controls)

    #expect(hasActiveFilters == true)
  }
}
