import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case general
  case focusMode
  case banners
  case appearance
  case notifications
  case voice
  case connection
  case taskBoard
  case policies
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
    case .focusMode: "Focus Mode"
    case .banners: "Banners"
    case .appearance: "Appearance"
    case .notifications: "Notifications"
    case .voice: "Voice"
    case .connection: "Connection"
    case .taskBoard: "Task Board"
    case .policies: "Policies"
    case .codex: "Codex"
    case .mcp: "MCP"
    case .authorizedFolders: "Authorized Folders"
    case .supervisor: "Supervisor"
    case .database: "Database"
    case .diagnostics: "Diagnostics"
    }
  }

  public var sidebarTitle: String {
    switch self {
    case .focusMode: "Focus"
    default: title
    }
  }

  public var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .focusMode: "moon"
    case .banners: "megaphone"
    case .appearance: "paintbrush"
    case .notifications: "bell.badge"
    case .voice: "mic"
    case .connection: "bolt.horizontal.circle"
    case .taskBoard: "list.bullet.rectangle"
    case .policies: "point.3.connected.trianglepath.dotted"
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
    content
      .modifier(SettingsScrollRestorationModifier())
      .harnessNativeFormContainer()
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
      Label(section.sidebarTitle, systemImage: section.systemImage)
        .scaledFont(.body)
        .padding(.vertical, rowPadding)
        .tag(section)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsSectionButton(section.rawValue)
        )
        .accessibilityValue(
          selection == section ? "selected" : "not selected"
        )
        .accessibilityFrameMarker(
          "\(HarnessMonitorAccessibility.settingsSectionButton(section.rawValue)).frame"
        )
    }
    .listStyle(.sidebar)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.settingsSidebar)
  }
}
