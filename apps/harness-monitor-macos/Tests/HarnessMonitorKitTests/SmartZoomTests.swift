import CoreGraphics
import Testing

@testable import HarnessMonitorUI

@Suite("Smart zoom configuration")
struct SmartZoomTests {
  @Test("Default zoom scale is 2.0")
  func defaultZoomScale() {
    #expect(SmartZoomConfiguration.zoomScale == 2.0)
  }

  @Test("Effective scale is 1.0 when inactive")
  func effectiveScaleWhenInactive() {
    #expect(SmartZoomConfiguration.effectiveScale(isActive: false) == 1.0)
  }

  @Test("Effective scale matches zoom scale when active")
  func effectiveScaleWhenActive() {
    #expect(
      SmartZoomConfiguration.effectiveScale(isActive: true)
        == SmartZoomConfiguration.zoomScale)
  }

  @Test("Animation duration is positive and reasonable")
  func animationDuration() {
    #expect(SmartZoomConfiguration.animationDuration > 0)
    #expect(SmartZoomConfiguration.animationDuration <= 1.0)
  }

  @Test("Scrollable content size is zoom scale times container size")
  func scrollableContentSize() {
    let containerWidth: CGFloat = 900
    let containerHeight: CGFloat = 600
    let scale = SmartZoomConfiguration.zoomScale
    #expect(containerWidth * scale == 1800)
    #expect(containerHeight * scale == 1200)
  }

  @MainActor
  @Test("Assigning the same navigation availability does not invalidate observers")
  func assigningSameNavigationAvailabilityDoesNotInvalidateObservers() async {
    let state = WindowNavigationState()

    let invalidated = await didInvalidate({ state.canGoBack }) {
      state.canGoBack = false
    }

    #expect(invalidated == false)
  }

  @MainActor
  @Test("Updating navigation handlers does not invalidate availability observers")
  func updatingNavigationHandlersDoesNotInvalidateAvailabilityObservers() async {
    let state = WindowNavigationState()

    let invalidated = await didInvalidate({ (state.canGoBack, state.canGoForward) }) {
      state.backHandler = { await Task.yield() }
      state.forwardHandler = { await Task.yield() }
    }

    #expect(invalidated == false)
  }
}
