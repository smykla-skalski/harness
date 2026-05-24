import SwiftUI

/// Animation curves used by the Open Anything palette. Mirrors
/// `OpenRecentCloseAfterPickMotionPolicy`: when `accessibilityReduceMotion`
/// is active, every animation collapses to a near-instant `.linear(0.01)`
/// so users who opt out of motion get no scale or fade.
public enum OpenAnythingMotionPolicy {
  /// Curve used when presenting the palette overlay.
  public static func presentAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18)
  }

  /// Curve used when dismissing the palette overlay.
  public static func dismissAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeIn(duration: 0.14)
  }

  /// Spring used to animate the selection rectangle inside the palette.
  public static func selectionAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.18, bounce: 0.1)
  }

  /// Curve used for the hover tint shift on a palette row.
  public static func hoverAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.1)
  }

  /// Curve used when the search result set shifts. Short enough that
  /// keystrokes still feel snappy, eased enough that the eye can track row
  /// movement.
  public static func resultShiftAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.16)
  }
}
