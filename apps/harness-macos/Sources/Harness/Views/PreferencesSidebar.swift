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
  static let sidebarWidth: CGFloat = 238
  static let sidebarLeadingInset: CGFloat = 20
  static let sidebarTrailingInset: CGFloat = 16
  static let sidebarTopInset: CGFloat = 28
  static let sidebarBottomInset: CGFloat = 20
  static let sectionSpacing: CGFloat = 8
  static let sectionRowHeight: CGFloat = 48
  static let shellDividerOpacity: Double = 0.42
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
    ZStack(alignment: .topLeading) {
      PreferencesWindowBackground(themeStyle: themeStyle)

      PreferencesSidebarChrome(themeStyle: themeStyle)

      HStack(spacing: 0) {
        PreferencesSidebarContent(
          selection: $selection,
          themeStyle: themeStyle
        )
        .frame(width: PreferencesChromeMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)

        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    GeometryReader { proxy in
      ZStack(alignment: .trailing) {
        HarnessTheme.sidebarBackground(for: themeStyle)

        Rectangle()
          .fill(
            HarnessTheme.panelBorder(for: themeStyle)
              .opacity(PreferencesChromeMetrics.shellDividerOpacity)
          )
          .frame(width: 1)
      }
      .frame(
        width: PreferencesChromeMetrics.sidebarWidth,
        height: proxy.size.height + proxy.safeAreaInsets.top,
        alignment: .topLeading
      )
      .offset(y: -proxy.safeAreaInsets.top)
      .accessibilityFrameMarker(HarnessAccessibility.preferencesSidebar)
    }
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
      .padding(.top, PreferencesChromeMetrics.sidebarTopInset)
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
        .padding(.horizontal, 14)
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
