import SwiftUI

enum SessionContentDetailSplitLayout {
  static let defaultContentWidth: Double = 440
  static let minimumContentWidth: CGFloat = 280
  static let minimumDetailWidth: CGFloat = 320

  static func preferredContentWidth(_ storedWidth: Double) -> CGFloat {
    max(CGFloat(storedWidth), minimumContentWidth)
  }
}

struct SessionContentDetailSplitView<Content: View, Detail: View>: View {
  private let contentWidth: Double
  private let content: Content
  private let detail: Detail

  init(
    contentWidth: Double,
    @ViewBuilder content: () -> Content,
    @ViewBuilder detail: () -> Detail
  ) {
    self.contentWidth = contentWidth
    self.content = content()
    self.detail = detail()
  }

  var body: some View {
    HSplitView {
      content
        .frame(
          minWidth: SessionContentDetailSplitLayout.minimumContentWidth,
          idealWidth: SessionContentDetailSplitLayout.preferredContentWidth(contentWidth),
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .topLeading
        )

      detail
        .frame(
          minWidth: SessionContentDetailSplitLayout.minimumDetailWidth,
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .topLeading
        )
        .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
