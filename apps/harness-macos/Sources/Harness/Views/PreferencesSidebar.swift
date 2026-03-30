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
  static let sidebarLeadingInset: CGFloat = 12
  static let sidebarTrailingInset: CGFloat = 8
  static let sidebarTopInset: CGFloat = 28
  static let sidebarBottomInset: CGFloat = 20
  static let sidebarButtonHorizontalInset: CGFloat = 6
  static let detailContentHorizontalInset: CGFloat = 0
  static let sectionSpacing: CGFloat = 8
  static let sectionRowHeight: CGFloat = 48
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
            selection: $selection,
            themeStyle: themeStyle
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
  let themeStyle: HarnessThemeStyle

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: PreferencesChromeMetrics.sectionSpacing) {
        ForEach(PreferencesSection.allCases) { section in
          PreferencesSidebarButton(
            section: section,
            isSelected: selection == section,
            themeStyle: themeStyle
          ) {
            selection = section
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.leading, PreferencesChromeMetrics.sidebarLeadingInset)
      .padding(.trailing, PreferencesChromeMetrics.sidebarTrailingInset)
      .padding(.bottom, PreferencesChromeMetrics.sidebarBottomInset)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
  }
}

private struct PreferencesSidebarButton: View {
  let section: PreferencesSection
  let isSelected: Bool
  let themeStyle: HarnessThemeStyle
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      Label(section.title, systemImage: section.systemImage)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .frame(
          maxWidth: .infinity,
          minHeight: PreferencesChromeMetrics.sectionRowHeight,
          alignment: .leading
        )
        .padding(.horizontal, PreferencesChromeMetrics.sidebarButtonHorizontalInset)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? HarnessTheme.ink : HarnessTheme.secondaryInk)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(HarnessTheme.surface(for: themeStyle).opacity(0.28))
          .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .stroke(
                HarnessTheme.panelBorder(for: themeStyle).opacity(0.26),
                lineWidth: 1
              )
          }
      }
    }
    .accessibilityIdentifier(
      HarnessAccessibility.preferencesSectionButton(section.rawValue)
    )
    .accessibilityValue(
      isSelected ? "selected" : "not selected"
    )
  }
}
