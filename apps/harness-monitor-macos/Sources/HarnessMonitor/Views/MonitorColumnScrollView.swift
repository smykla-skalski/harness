import SwiftUI

struct MonitorColumnScrollView<Content: View>: View {
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat
  @ViewBuilder private let content: () -> Content

  init(
    horizontalPadding: CGFloat = 24,
    verticalPadding: CGFloat = 24,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.horizontalPadding = horizontalPadding
    self.verticalPadding = verticalPadding
    self.content = content
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 0) {
        content()
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
