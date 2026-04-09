import HarnessMonitorUI
import Lottie
import SwiftUI

struct HarnessMonitorAppLlamaAnimation: View {
  private enum Constants {
    static let assetName = "DancingLlama"
    static let width: CGFloat = 200
    static let height: CGFloat = 200
    static let speed = 1.0
  }

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    LottieView(animation: .named(Constants.assetName, bundle: HarnessMonitorUIAssets.bundle))
      .playing(loopMode: reduceMotion ? .playOnce : .loop)
      .animationSpeed(reduceMotion ? 0 : Constants.speed)
      .frame(width: Constants.width, height: Constants.height)
      .accessibilityHidden(true)
  }
}
