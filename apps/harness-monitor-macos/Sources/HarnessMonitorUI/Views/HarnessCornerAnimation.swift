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
