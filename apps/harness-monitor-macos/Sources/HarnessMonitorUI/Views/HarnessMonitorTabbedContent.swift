import SwiftUI

enum HarnessMonitorTabbedContentDistribution {
  case fitContent
  case fillEqually
}

enum HarnessMonitorTabbedContentAlignment {
  case leading
  case trailing
}

struct HarnessMonitorTabbedContent<
  Tab: Hashable & CaseIterable & Identifiable,
  Content: View
>: View {
  let title: String
  @Binding var selection: Tab
  let tabTitle: (Tab) -> String
  let distribution: HarnessMonitorTabbedContentDistribution
  let alignment: HarnessMonitorTabbedContentAlignment
  let tabsDisabled: Bool
  let pickerAccessibilityIdentifier: String?
  @ViewBuilder let content: (Tab) -> Content

  init(
    title: String,
    selection: Binding<Tab>,
    tabTitle: @escaping (Tab) -> String,
    distribution: HarnessMonitorTabbedContentDistribution = .fitContent,
    alignment: HarnessMonitorTabbedContentAlignment = .leading,
    tabsDisabled: Bool = false,
    pickerAccessibilityIdentifier: String? = nil,
    @ViewBuilder content: @escaping (Tab) -> Content
  ) {
    self.title = title
    self._selection = selection
    self.tabTitle = tabTitle
    self.distribution = distribution
    self.alignment = alignment
    self.tabsDisabled = tabsDisabled
    self.pickerAccessibilityIdentifier = pickerAccessibilityIdentifier
    self.content = content
  }

  var body: some View {
    Section {
      pickerRow
      content(selection)
    } header: {
      Text(title)
    }
  }

  private var pickerRow: some View {
    HStack(spacing: 0) {
      Picker(title, selection: $selection) {
        ForEach(Array(Tab.allCases)) { tab in
          Text(tabTitle(tab)).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .harnessNativeFormControl()
      .disabled(tabsDisabled)
      .frame(maxWidth: distribution == .fillEqually ? .infinity : nil)
    }
    .frame(maxWidth: .infinity, alignment: pickerAlignment)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(pickerAccessibilityIdentifier ?? title)
  }

  private var pickerAlignment: Alignment {
    switch alignment {
    case .leading:
      .leading
    case .trailing:
      .trailing
    }
  }
}
