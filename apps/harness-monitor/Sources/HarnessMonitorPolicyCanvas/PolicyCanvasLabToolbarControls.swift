import SwiftUI

public struct PolicyCanvasLabThemePicker: View {
  @Binding var windowThemeMode: PolicyCanvasLabThemeMode

  public init(windowThemeMode: Binding<PolicyCanvasLabThemeMode>) {
    _windowThemeMode = windowThemeMode
  }

  public var body: some View {
    Menu {
      Picker("Window theme", selection: $windowThemeMode) {
        ForEach(PolicyCanvasLabThemeMode.allCases) { mode in
          Label(mode.label, systemImage: mode.labToolbarSystemImage).tag(mode)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Image(systemName: windowThemeMode.labToolbarSystemImage)
        .accessibilityHidden(true)
    }
    .help(
      "Choose the Policy Canvas Lab window theme."
    )
    .accessibilityLabel("Window theme")
    .accessibilityValue(windowThemeMode.label)
  }
}

extension PolicyCanvasLabThemeMode {
  fileprivate var labToolbarSystemImage: String {
    switch self {
    case .light: "sun.max"
    case .dark: "moon"
    }
  }
}

public struct PolicyCanvasLabToolbarTextMenuLabel: View {
  let title: String

  public init(title: String) {
    self.title = title
  }

  @ScaledMetric(relativeTo: .callout)
  private var itemSpacing = 6.0

  @ScaledMetric(relativeTo: .callout)
  private var horizontalContentPadding = 6.0

  public var body: some View {
    HStack(spacing: itemSpacing) {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
      Image(systemName: "chevron.down")
        .imageScale(.small)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, horizontalContentPadding)
  }
}
