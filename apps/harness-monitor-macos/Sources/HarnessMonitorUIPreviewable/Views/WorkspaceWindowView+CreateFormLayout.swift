import SwiftUI

extension WorkspaceWindowCreatePane {
  @ViewBuilder
  func createPaneColumns<Leading: View, Trailing: View>(
    leadingMaxWidth: CGFloat? = nil,
    hstackMinWidth: CGFloat = 720,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    let leadingView = leading()
    let trailingView = trailing()
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
        leadingView
          .frame(maxWidth: leadingMaxWidth, alignment: .leading)
        trailingView
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minWidth: hstackMinWidth)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        leadingView
          .frame(maxWidth: .infinity, alignment: .leading)
        trailingView
      }
    }
  }
}
