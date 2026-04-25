import SwiftUI

public struct ContentCornerOverlayModifier<CornerContent: View>: ViewModifier {
  public let isPresented: Bool
  public let cornerAnimationContent: CornerContent

  public init(isPresented: Bool, cornerAnimationContent: CornerContent) {
    self.isPresented = isPresented
    self.cornerAnimationContent = cornerAnimationContent
  }

  public func body(content: Content) -> some View {
    content
      .modifier(
        HarnessCornerOverlayModifier(
          isPresented: isPresented,
          configuration: .init(
            width: HarnessCornerAnimationDescriptor.dancingLlama.width,
            height: HarnessCornerAnimationDescriptor.dancingLlama.height,
            trailingPadding: HarnessCornerAnimationDescriptor.dancingLlama.trailingPadding,
            bottomPadding: HarnessCornerAnimationDescriptor.dancingLlama.bottomPadding,
            contentPadding: 0,
            appliesGlass: false,
            accessibilityLabel: HarnessCornerAnimationDescriptor.dancingLlama.accessibilityLabel,
            presentationDelay: nil
          )
        ) {
          cornerAnimationContent
        }
      )
  }
}
