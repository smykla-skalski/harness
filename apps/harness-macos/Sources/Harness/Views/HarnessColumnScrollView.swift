import SwiftUI

struct HarnessColumnScrollView<Content: View>: View {
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  private let content: Content

  init(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        content
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
