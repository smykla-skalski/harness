import SwiftUI

public enum PreferencesSection: String, CaseIterable, Identifiable, Hashable {
  case general
  case appearance
  case notifications
  case voice
  case connection
  case codex
  case database
  case diagnostics

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .notifications: "Notifications"
    case .voice: "Voice"
    case .connection: "Connection"
    case .codex: "Codex"
    case .database: "Database"
    case .diagnostics: "Diagnostics"
    }
  }

  public var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .notifications: "bell.badge"
    case .voice: "mic"
    case .connection: "bolt.horizontal.circle"
    case .codex: "terminal"
    case .database: "cylinder.split.1x2"
    case .diagnostics: "stethoscope"
    }
  }
}

public enum PreferencesChromeMetrics {
  public static let sidebarMinWidth: CGFloat = 200
  public static let sidebarIdealWidth: CGFloat = 210
  public static let sidebarMaxWidth: CGFloat = 240
  public static let sidebarMinRowHeight: CGFloat = 30
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

public struct PreferencesSidebarList: View {
  @Binding public var selection: PreferencesSection
  @Environment(\.fontScale)
  private var fontScale

  public init(selection: Binding<PreferencesSection>) {
    _selection = selection
  }

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  public var body: some View {
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
