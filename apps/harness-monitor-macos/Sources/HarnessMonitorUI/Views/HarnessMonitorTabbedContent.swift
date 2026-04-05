import SwiftUI

enum HarnessMonitorTabbedContentDistribution {
  case fitContent
  case fillEqually
}

enum HarnessMonitorTabbedContentAlignment {
  case leading
  case trailing
}

struct HarnessMonitorTabbedContent<Tab: Hashable & CaseIterable & Identifiable, Content: View>: View {
  let title: String
  @Binding var selection: Tab
  let tabTitle: (Tab) -> String
  let distribution: HarnessMonitorTabbedContentDistribution
  let alignment: HarnessMonitorTabbedContentAlignment
  @ViewBuilder let content: (Tab) -> Content

  @Namespace private var tabNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    title: String,
    selection: Binding<Tab>,
    tabTitle: @escaping (Tab) -> String,
    distribution: HarnessMonitorTabbedContentDistribution = .fitContent,
    alignment: HarnessMonitorTabbedContentAlignment = .leading,
    @ViewBuilder content: @escaping (Tab) -> Content
  ) {
    self.title = title
    self._selection = selection
    self.tabTitle = tabTitle
    self.distribution = distribution
    self.alignment = alignment
    self.content = content
  }

  var body: some View {
    Section {
      content(selection)
    } header: {
      HStack(alignment: .center, spacing: 0) {
        Text(title)
          .scaledFont(.subheadline)
        if alignment == .trailing {
          Spacer(minLength: 0)
        }
        ForEach(Array(Tab.allCases) as! [Tab]) { tab in
          let isSelected = selection == tab
          Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15)) {
              selection = tab
            }
          } label: {
            Text(tabTitle(tab))
              .scaledFont(.subheadline)
              .fontWeight(isSelected ? .semibold : .regular)
              .foregroundStyle(isSelected ? .primary : .secondary)
              .padding(.horizontal, HarnessMonitorTheme.spacingMD)
              .padding(.vertical, HarnessMonitorTheme.spacingSM)
              .frame(maxWidth: distribution == .fillEqually ? .infinity : nil)
              .background {
                if isSelected {
                  UnevenRoundedRectangle(
                    topLeadingRadius: 6,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 6,
                    style: .continuous
                  )
                  .fill(Color(nsColor: .quaternarySystemFill))
                  .matchedGeometryEffect(id: "tab-background", in: tabNamespace)
                }
              }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(tabTitle(tab))
          .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
      .padding(.bottom, -(HarnessMonitorTheme.spacingSM + 2))
    }
  }
}
