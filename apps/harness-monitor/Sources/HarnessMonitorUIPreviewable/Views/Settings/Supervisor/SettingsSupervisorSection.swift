import HarnessMonitorKit
import SwiftUI

/// Key identifying which Supervisor settings pane is currently selected.
public enum SupervisorPaneKey: String, CaseIterable, Hashable, Identifiable, Sendable {
  case rules
  case notifications
  case background
  case audit

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .rules: "Rules"
    case .notifications: "Notifications"
    case .background: "Background"
    case .audit: "Audit"
    }
  }

  /// Panes that the toolbar segmented picker should surface.
  public static let toolbarVisibleCases: [Self] = [
    .rules, .notifications, .background, .audit,
  ]
}

/// Root Supervisor section in the Settings window. The pane switcher lives in the window
/// toolbar, while each pane owns its own `Form` and `settingsDetailFormStyle()`.
public struct SettingsSupervisorSection: View {
  let store: HarnessMonitorStore
  let notifications: HarnessMonitorUserNotificationController
  @Binding var selectedPane: SupervisorPaneKey
  @Environment(\.settingsScrollRestorationSection)
  private var settingsSection
  @State private var visitedPanes: Set<SupervisorPaneKey> = []

  public init(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController,
    selectedPane: Binding<SupervisorPaneKey>
  ) {
    self.store = store
    self.notifications = notifications
    _selectedPane = selectedPane
  }

  public var body: some View {
    SupervisorRetainedPaneLayout(selectedPane: selectedPane) {
      ForEach(SupervisorPaneKey.toolbarVisibleCases) { pane in
        if visitedPanes.contains(pane) {
          let isSelected = pane == selectedPane
          SupervisorRetainedPaneHost(
            pane: pane,
            isSelected: isSelected,
            settingsSection: settingsSection
          ) {
            paneContent(pane)
          }
          .equatable()
          .layoutValue(key: SupervisorRetainedPaneKey.self, value: pane)
        }
      }
    }
    .onChange(of: selectedPane, initial: true) { _, newValue in
      visitedPanes.insert(newValue)
    }
  }

  @ViewBuilder
  private func paneContent(_ pane: SupervisorPaneKey) -> some View {
    switch pane {
    case .rules:
      SettingsSupervisorRulesPane(store: store)
    case .notifications:
      SettingsSupervisorNotificationsPane(notifications: notifications)
    case .background:
      SettingsSupervisorBackgroundPane(
        onRunInBackgroundChange: { enabled in
          store.setSupervisorRunInBackgroundEnabled(enabled)
        },
        onQuietHoursChange: { window, _ in
          store.setSupervisorQuietHoursWindow(window)
        }
      )
    case .audit:
      SettingsSupervisorAuditPane(store: store)
    }
  }
}

private struct SupervisorRetainedPaneHost<Content: View>: View, Equatable {
  let pane: SupervisorPaneKey
  let isSelected: Bool
  let settingsSection: SettingsSection?
  private let content: () -> Content

  init(
    pane: SupervisorPaneKey,
    isSelected: Bool,
    settingsSection: SettingsSection?,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.pane = pane
    self.isSelected = isSelected
    self.settingsSection = settingsSection
    self.content = content
  }

  var body: some View {
    content()
      .environment(\.settingsScrollRestorationSection, isSelected ? settingsSection : nil)
      .harnessMCPElementTrackingEnabled(isSelected)
      .opacity(isSelected ? 1 : 0)
      .allowsHitTesting(isSelected)
      .accessibilityHidden(!isSelected)
  }

  nonisolated static func == (
    lhs: SupervisorRetainedPaneHost<Content>,
    rhs: SupervisorRetainedPaneHost<Content>
  ) -> Bool {
    lhs.pane == rhs.pane
      && lhs.isSelected == rhs.isSelected
      && lhs.settingsSection == rhs.settingsSection
  }
}

private struct SupervisorRetainedPaneLayout: Layout {
  let selectedPane: SupervisorPaneKey

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    selectedSubview(in: subviews)?.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }

  func explicitAlignment(
    of _: HorizontalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  func explicitAlignment(
    of _: VerticalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { subview in
      subview[SupervisorRetainedPaneKey.self] == selectedPane
    } ?? subviews.first
  }
}

private struct SupervisorRetainedPaneKey: LayoutValueKey {
  static let defaultValue: SupervisorPaneKey? = nil
}

private enum SupervisorPaneToolbarMetrics {
  static let width: CGFloat = 380
}

struct SupervisorSettingsToolbarPicker: View {
  @Binding var selection: SupervisorPaneKey

  var body: some View {
    Picker("Pane", selection: $selection) {
      ForEach(SupervisorPaneKey.toolbarVisibleCases) { pane in
        Text(pane.title)
          .tag(pane)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.settingsSupervisorPane("pane-picker"),
              option: pane.title
            )
          )
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.large)
    .frame(width: SupervisorPaneToolbarMetrics.width)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsSupervisorPane("pane-picker")
    )
  }
}
