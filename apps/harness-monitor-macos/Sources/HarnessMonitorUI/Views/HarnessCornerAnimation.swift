import Lottie
import SwiftUI

struct HarnessCornerAnimationDescriptor: Equatable {
  let assetName: String
  let width: CGFloat
  let height: CGFloat
  let trailingPadding: CGFloat
  let bottomPadding: CGFloat
  let speed: Double
  let accessibilityLabel: String

  static let dancingLlama = Self(
    assetName: "DancingLlama",
    width: 200,
    height: 200,
    trailingPadding: -30,
    bottomPadding: 4,
    speed: 1,
    accessibilityLabel: "Dancing llama"
  )
}

struct HarnessCornerAnimation: View {
  let descriptor: HarnessCornerAnimationDescriptor

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    LottieView(animation: .named(descriptor.assetName, bundle: HarnessMonitorUIAssets.bundle))
      .playing(loopMode: reduceMotion ? .playOnce : .loop)
      .animationSpeed(reduceMotion ? 0 : descriptor.speed)
      .frame(width: descriptor.width, height: descriptor.height)
      .accessibilityHidden(true)
  }
}
