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

  var body: some View {
    Group {
      if constrainContentWidth {
        GeometryReader { geometry in
          scrollBody(contentWidth: max(geometry.size.width - (horizontalPadding * 2), 0))
        }
      } else {
        scrollBody()
      }
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func scrollBody(contentWidth: CGFloat? = nil) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        if let contentWidth {
          content
            .frame(width: contentWidth, alignment: .topLeading)
        } else {
          content
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
    }
  }
}
