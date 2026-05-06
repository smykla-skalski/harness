import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
  case general
  case appearance
  case notifications
  case voice
  case connection
  case codex
  case mcp
  case authorizedFolders
  case supervisor
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
    case .mcp: "MCP"
    case .authorizedFolders: "Authorized Folders"
    case .supervisor: "Supervisor"
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
    case .mcp: "bolt.shield"
    case .authorizedFolders: "folder.badge.person.crop"
    case .supervisor: "eye"
    case .database: "cylinder.split.1x2"
    case .diagnostics: "stethoscope"
    }
  }
}

public enum SettingsChromeMetrics {
  public static let sidebarMinWidth: CGFloat = 200
  public static let sidebarIdealWidth: CGFloat = 210
  public static let sidebarMaxWidth: CGFloat = 240
  public static let sidebarMinRowHeight: CGFloat = 30
}

struct SettingsDetailFormModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.harnessNativeFormContainer()
  }
}

extension View {
  func settingsDetailFormStyle() -> some View {
    modifier(SettingsDetailFormModifier())
  }
}

public struct SettingsSidebarList: View {
  @Binding public var selection: SettingsSection
  @Environment(\.fontScale)
  private var fontScale

  public init(selection: Binding<SettingsSection>) {
    _selection = selection
  }

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  public var body: some View {
    List(SettingsSection.allCases, selection: $selection) { section in
      Label(section.title, systemImage: section.systemImage)
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(section)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsSectionButton(section.rawValue)
        )
        .accessibilityValue(
          selection == section ? "selected" : "not selected"
        )
    }
    .listStyle(.sidebar)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.settingsSidebar)
  }
}
