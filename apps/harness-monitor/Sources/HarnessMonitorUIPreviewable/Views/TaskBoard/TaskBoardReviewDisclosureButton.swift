import SwiftUI

struct TaskBoardReviewDisclosureButton: View {
  let collapsedTitle: String
  let expandedTitle: String
  @Binding var isExpanded: Bool
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Label(
        isExpanded ? expandedTitle : collapsedTitle,
        systemImage: isExpanded ? "minus.circle" : "ellipsis.circle"
      )
      .font(HarnessMonitorTextSize.scaledFont(.caption2.weight(.semibold), by: fontScale))
      .imageScale(.small)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .fixedSize()
      .frame(maxWidth: .infinity)
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
