import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane header fade")
struct TaskBoardLaneHeaderFadeTests {
  private struct Appearance {
    let reduceTransparency: Bool
    let increasesContrast: Bool
  }

  private static let appearances = [
    Appearance(reduceTransparency: false, increasesContrast: false),
    Appearance(reduceTransparency: true, increasesContrast: false),
    Appearance(reduceTransparency: false, increasesContrast: true),
    Appearance(reduceTransparency: true, increasesContrast: true),
  ]

  private func fade(
    isHovered: Bool = false,
    isPressed: Bool = false,
    appearance: Appearance
  ) -> TaskBoardLaneHeaderFade {
    TaskBoardLaneHeaderFade(
      isHovered: isHovered,
      isPressed: isPressed,
      reduceTransparency: appearance.reduceTransparency,
      increasesContrast: appearance.increasesContrast
    )
  }

  /// What the layer actually paints: the gradient carries each stop's weight and
  /// the layer scales the whole thing by `intensity`.
  private func stopOpacities(_ fade: TaskBoardLaneHeaderFade) -> [Double] {
    TaskBoardLaneHeaderFade.stops.map { fade.intensity * $0.weight }
  }

  @Test("A lane header at rest draws nothing")
  func laneHeaderAtRestDrawsNothing() {
    for appearance in Self.appearances {
      let resting = fade(appearance: appearance)

      #expect(resting.intensity == 0)
      #expect(!resting.isActive)
      #expect(stopOpacities(resting).allSatisfy { $0 == 0 })
    }
  }

  @Test("The fade is strongest at the top edge and reaches zero at the bottom")
  func fadeIsStrongestAtTopAndReachesZeroAtBottom() throws {
    let stops = TaskBoardLaneHeaderFade.stops

    #expect(stops.first?.location == 0)
    #expect(stops.last?.location == 1)
    #expect(stops.last?.weight == 0)
    #expect(stops.count >= 2)
    #expect(stops.map(\.location) == stops.map(\.location).sorted())

    for appearance in Self.appearances {
      let opacities = stopOpacities(fade(isHovered: true, appearance: appearance))
      let strictlyFalling = zip(opacities, opacities.dropFirst()).allSatisfy { $0 > $1 }

      #expect(strictlyFalling)
      #expect(opacities.last == 0)
    }
  }

  @Test("Pressing deepens the same gradient rather than adding a second effect")
  func pressingDeepensTheSameGradient() {
    for appearance in Self.appearances {
      let hovered = fade(isHovered: true, appearance: appearance)
      let pressed = fade(isHovered: true, isPressed: true, appearance: appearance)

      #expect(hovered.intensity > 0)
      #expect(pressed.intensity > hovered.intensity)
      // Same stop profile, scaled: the two states cannot read as different shapes.
      #expect(
        zip(stopOpacities(pressed), stopOpacities(hovered)).allSatisfy { $0 >= $1 }
      )
    }
  }

  @Test("A press without hover still draws the fade")
  func pressWithoutHoverStillDrawsTheFade() {
    for appearance in Self.appearances {
      #expect(fade(isPressed: true, appearance: appearance).isActive)
    }
  }

  @Test("Reduce Transparency and Increase Contrast strengthen the fade")
  func accessibilityAppearancesStrengthenTheFade() {
    let plain = Appearance(reduceTransparency: false, increasesContrast: false)

    for appearance in Self.appearances.dropFirst() {
      for isPressed in [false, true] {
        let baseline = fade(isHovered: true, isPressed: isPressed, appearance: plain)
        let adjusted = fade(isHovered: true, isPressed: isPressed, appearance: appearance)

        #expect(adjusted.intensity > baseline.intensity)
      }
    }
  }

  @Test("The loudest reachable state stays clear of the ceiling")
  func loudestReachableStateStaysClearOfTheCeiling() {
    let loudest = fade(
      isHovered: true,
      isPressed: true,
      appearance: Appearance(reduceTransparency: true, increasesContrast: true)
    )

    // Strictly below the cap, not merely at it. Once the boosts push a state
    // onto the ceiling, appearances that should differ clamp to one wash.
    #expect(loudest.intensity < TaskBoardLaneHeaderFade.maximumIntensity)
  }

  @Test("Reduce Motion drops the transition, everything else keeps it")
  func reduceMotionDropsTheTransition() {
    #expect(TaskBoardLaneHeaderFade.hoverAnimation(reduceMotion: true) == nil)
    #expect(TaskBoardLaneHeaderFade.pressAnimation(reduceMotion: true) == nil)
    #expect(TaskBoardLaneHeaderFade.hoverAnimation(reduceMotion: false) != nil)
    #expect(TaskBoardLaneHeaderFade.pressAnimation(reduceMotion: false) != nil)
  }
}
