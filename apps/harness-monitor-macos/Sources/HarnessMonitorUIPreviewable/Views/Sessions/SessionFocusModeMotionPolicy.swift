import SwiftUI

enum SessionFocusModeMotionPolicy {
  static let transitionDuration: Double = 0.22

  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeInOut(duration: transitionDuration)
  }
}
