import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("SessionTimeline placeholder shimmer")
struct SessionTimelinePlaceholderShimmerTests {
  @Test("Shared shimmer animates only when unresolved placeholders are visible")
  func sharedShimmerAnimatesOnlyWhenNeeded() {
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 4
      )
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: true,
        placeholderCount: 4
      ) == false
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 0
      ) == false
    )
  }

  @Test("Shared shimmer phase stays in the expected horizontal travel range")
  func sharedShimmerPhaseStaysInExpectedRange() {
    let cycleDuration = SessionTimelinePlaceholderShimmer.cycleDuration
    let phaseAtStart = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: 0)
    )
    let phaseMidCycle = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration / 2)
    )
    let phaseAtWrap = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration)
    )

    #expect(phaseAtStart == -0.6)
    #expect(phaseMidCycle == 0.6)
    #expect(phaseAtWrap == -0.6)
  }
}
