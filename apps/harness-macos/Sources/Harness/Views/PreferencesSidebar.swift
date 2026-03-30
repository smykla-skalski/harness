import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable, Hashable {
  case general
  case connection
  case diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .connection: "Connection"
    case .diagnostics: "Diagnostics"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .connection: "bolt.horizontal.circle"
    case .diagnostics: "stethoscope"
    }
  }
}

enum PreferencesChromeMetrics {
  static let sidebarWidth: CGFloat = 220
  static let sidebarBottomInset: CGFloat = 20
  static let sidebarMinRowHeight: CGFloat = 30
  static let detailContentHorizontalInset: CGFloat = -18
}

struct PreferencesDetailFormModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .formStyle(.grouped)
      .contentMargins(
        .horizontal,
        PreferencesChromeMetrics.detailContentHorizontalInset,
        for: .scrollContent
      )
  }
}

extension View {
  func preferencesDetailFormStyle() -> some View {
    modifier(PreferencesDetailFormModifier())
  }
}

struct PreferencesChromeLayout<Detail: View>: View {
  @Binding var selection: PreferencesSection
  private let detail: Detail

  init(
    selection: Binding<PreferencesSection>,
    @ViewBuilder detail: () -> Detail
  ) {
    _selection = selection
    self.detail = detail()
  }

  var body: some View {
    NavigationSplitView {
      PreferencesSidebarContent(selection: $selection)
        .navigationSplitViewColumnWidth(
          min: PreferencesChromeMetrics.sidebarWidth,
          ideal: PreferencesChromeMetrics.sidebarWidth,
          max: PreferencesChromeMetrics.sidebarWidth
        )
        .accessibilityFrameMarker(HarnessAccessibility.preferencesSidebar)
    } detail: {
      detail
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .topLeading
        )
    }
    .navigationSplitViewStyle(.balanced)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PreferencesSidebarContent: View {
  @Binding var selection: PreferencesSection

  var body: some View {
    List(selection: $selection) {
      ForEach(PreferencesSection.allCases) { section in
        PreferencesSidebarRow(
          section: section,
          isSelected: selection == section
        )
        .tag(section)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesSectionButton(section.rawValue)
        )
        .accessibilityValue(
          selection == section ? "selected" : "not selected"
        )
      }
    }
    .listStyle(.sidebar)
    .controlSize(.small)
    .environment(\.sidebarRowSize, .small)
    .environment(\.defaultMinListRowHeight, PreferencesChromeMetrics.sidebarMinRowHeight)
    .safeAreaPadding(.bottom, PreferencesChromeMetrics.sidebarBottomInset)
  }
}

private struct PreferencesSidebarRow: View {
  let section: PreferencesSection
  let isSelected: Bool

  var body: some View {
    Label(section.title, systemImage: section.systemImage)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(
        isSelected ? Color.primary : Color.primary.opacity(0.82)
      )
  }
}
