import HarnessMonitorUI
#if canImport(Lottie)
import Lottie
#endif
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
#if canImport(Lottie)
    LottieView(animation: .named(Constants.assetName, bundle: HarnessMonitorUIAssets.bundle))
      .playing(loopMode: reduceMotion ? .playOnce : .loop)
      .animationSpeed(reduceMotion ? 0 : Constants.speed)
      .frame(width: Constants.width, height: Constants.height)
      .accessibilityHidden(true)
#else
    // The isolated UI-test host compiles the app sources without the optional
    // animation package. Keep the layout contract without taking a new target dependency.
    Color.clear
      .frame(width: Constants.width, height: Constants.height)
      .accessibilityHidden(true)
#endif
  }
}
