import Lottie
import SwiftUI

struct HarnessCornerAnimation: View {
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    LottieView(animation: .named("DancingLlama", bundle: HarnessMonitorUIAssets.bundle))
      .playing(loopMode: reduceMotion ? .playOnce : .loop)
      .animationSpeed(reduceMotion ? 0 : 1)
      .accessibilityHidden(true)
  }
}
