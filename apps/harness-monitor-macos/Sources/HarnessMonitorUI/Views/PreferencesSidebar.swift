import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable, Hashable {
  case general
  case connection
  case database
  case diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .connection: "Connection"
    case .database: "Database"
    case .diagnostics: "Diagnostics"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .connection: "bolt.horizontal.circle"
    case .database: "cylinder.split.1x2"
    case .diagnostics: "stethoscope"
    }
  }
}

enum PreferencesChromeMetrics {
  static let sidebarMinWidth: CGFloat = 200
  static let sidebarIdealWidth: CGFloat = 210
  static let sidebarMaxWidth: CGFloat = 240
  static let sidebarMinRowHeight: CGFloat = 30
}

struct PreferencesDetailFormModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.harnessNativeFormContainer()
  }
}

extension View {
  func preferencesDetailFormStyle() -> some View {
    modifier(PreferencesDetailFormModifier())
  }
}

struct PreferencesSidebarList: View {
  @Binding var selection: PreferencesSection
  @Environment(\.fontScale) private var fontScale

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  var body: some View {
    List(PreferencesSection.allCases, selection: $selection) { section in
      Label(section.title, systemImage: section.systemImage)
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(section)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesSectionButton(section.rawValue)
        )
        .accessibilityValue(
          selection == section ? "selected" : "not selected"
        )
    }
    .listStyle(.sidebar)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.preferencesSidebar)
  }
}

#Preview("Preferences Sidebar") {
  @Previewable @State var selection: PreferencesSection = .diagnostics

  PreferencesSidebarList(selection: $selection)
    .frame(width: 220, height: 220)
}
