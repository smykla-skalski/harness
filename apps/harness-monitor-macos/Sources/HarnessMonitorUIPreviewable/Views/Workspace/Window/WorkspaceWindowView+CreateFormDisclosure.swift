import SwiftUI

struct WholeRowDisclosure<Content: View>: View {
  let label: String
  @ViewBuilder let content: () -> Content
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Image(systemName: "chevron.right")
            .scaledFont(.caption.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityHidden(true)
          Text(label)
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .harnessDismissButtonStyle()
      .accessibilityLabel(label)
      .accessibilityValue(isExpanded ? "expanded" : "collapsed")
      .accessibilityAddTraits(.isButton)

      if isExpanded {
        content()
          .padding(.top, HarnessMonitorTheme.spacingXS)
      }
    }
  }
}
