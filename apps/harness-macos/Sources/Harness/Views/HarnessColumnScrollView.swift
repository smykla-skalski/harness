import SwiftUI

struct HarnessColumnScrollView<Content: View>: View {
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  let constrainContentWidth: Bool
  private let content: Content

  init(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    constrainContentWidth: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.constrainContentWidth = constrainContentWidth
    self.content = content()
  }

  @State private var availableWidth: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if constrainContentWidth, availableWidth > 0 {
          content
            .frame(
              width: max(availableWidth - (horizontalPadding * 2), 0),
              alignment: .topLeading
            )
        } else {
          content
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { newWidth in
      availableWidth = newWidth
    }
  }
}
