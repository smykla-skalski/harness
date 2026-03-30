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
  static let sidebarTopInset: CGFloat = 8
  static let sidebarBottomInset: CGFloat = 20
  static let sidebarRowLeadingInset: CGFloat = 10
  static let sidebarRowTrailingInset: CGFloat = 10
  static let sidebarRowVerticalInset: CGFloat = 2
  static let sidebarMinRowHeight: CGFloat = 30
  static let detailContentHorizontalInset: CGFloat = -18
  static let shellDividerOpacity: Double = 0.42
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
  let themeStyle: HarnessThemeStyle
  @Binding var selection: PreferencesSection
  private let detail: Detail

  init(
    themeStyle: HarnessThemeStyle,
    selection: Binding<PreferencesSection>,
    @ViewBuilder detail: () -> Detail
  ) {
    self.themeStyle = themeStyle
    _selection = selection
    self.detail = detail()
  }

  var body: some View {
    GeometryReader { proxy in
      let topChromeInset = proxy.safeAreaInsets.top

      ZStack(alignment: .topLeading) {
        PreferencesWindowBackground(themeStyle: themeStyle)

        PreferencesSidebarChrome(themeStyle: themeStyle)

        HStack(spacing: 0) {
          PreferencesSidebarContent(
            selection: $selection
          )
          .padding(
            .top,
            topChromeInset + PreferencesChromeMetrics.sidebarTopInset
          )
          .frame(width: PreferencesChromeMetrics.sidebarWidth)
          .frame(maxHeight: .infinity, alignment: .topLeading)

          detail
            .padding(.top, topChromeInset)
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: .topLeading
            )
        }
      }
      .ignoresSafeArea(.container, edges: .top)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct PreferencesWindowBackground: View {
  let themeStyle: HarnessThemeStyle

  @ViewBuilder var body: some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      HarnessTheme.canvas(for: themeStyle)
        .backgroundExtensionEffect()
        .ignoresSafeArea()
    } else {
      HarnessTheme.canvas(for: themeStyle)
        .ignoresSafeArea()
    }
  }
}

private struct PreferencesSidebarChrome: View {
  let themeStyle: HarnessThemeStyle

  var body: some View {
    ZStack(alignment: .trailing) {
      HarnessTheme.sidebarBackground(for: themeStyle)

      Rectangle()
        .fill(
          HarnessTheme.panelBorder(for: themeStyle)
            .opacity(PreferencesChromeMetrics.shellDividerOpacity)
        )
        .frame(width: 1)
    }
    .frame(width: PreferencesChromeMetrics.sidebarWidth)
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .accessibilityFrameMarker(HarnessAccessibility.preferencesSidebar)
    .allowsHitTesting(false)
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
        .listRowInsets(
          EdgeInsets(
            top: PreferencesChromeMetrics.sidebarRowVerticalInset,
            leading: PreferencesChromeMetrics.sidebarRowLeadingInset,
            bottom: PreferencesChromeMetrics.sidebarRowVerticalInset,
            trailing: PreferencesChromeMetrics.sidebarRowTrailingInset
          )
        )
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
    .contentMargins(.top, 0, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .safeAreaPadding(.bottom, PreferencesChromeMetrics.sidebarBottomInset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
    .background(Color.clear)
  }
}

private struct PreferencesSidebarRow: View {
  let section: PreferencesSection
  let isSelected: Bool

  var body: some View {
    Label(section.title, systemImage: section.systemImage)
      .font(.system(.body, design: .rounded, weight: .semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(isSelected ? HarnessTheme.ink : HarnessTheme.secondaryInk)
  }
}
