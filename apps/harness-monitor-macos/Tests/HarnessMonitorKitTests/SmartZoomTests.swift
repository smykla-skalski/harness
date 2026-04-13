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
}
