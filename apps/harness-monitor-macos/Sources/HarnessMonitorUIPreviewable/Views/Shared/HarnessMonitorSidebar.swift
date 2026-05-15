import SwiftUI

struct HarnessMonitorSidebar<Content: View>: View {
  private let accessibilityIdentifier: String
  private let accessibilityValue: Text
  private let statusModel: SessionStatusSummaryModel
  private let rowSize: SidebarRowSize
  private let content: Content

  init(
    accessibilityIdentifier: String,
    accessibilityValue: Text = Text(""),
    statusModel: SessionStatusSummaryModel,
    rowSize: SidebarRowSize,
    @ViewBuilder content: () -> Content
  ) {
    self.accessibilityIdentifier = accessibilityIdentifier
    self.accessibilityValue = accessibilityValue
    self.statusModel = statusModel
    self.rowSize = rowSize
    self.content = content()
  }

  var body: some View {
    content
      .listStyle(.sidebar)
      .transaction { transaction in
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
      .environment(\.sidebarRowSize, rowSize)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SessionSidebarFooter(model: statusModel)
      }
      .accessibilityIdentifier(accessibilityIdentifier)
      .accessibilityValue(accessibilityValue)
  }
}
