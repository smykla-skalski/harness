import HarnessMonitorKit
import SwiftUI

public struct SettingsSupervisorAuditPane: View {
  @State private var viewModel: SettingsSupervisorAuditViewModel

  public init(userDefaults: UserDefaults = .standard) {
    _viewModel = State(
      initialValue: SettingsSupervisorAuditViewModel(userDefaults: userDefaults)
    )
  }

  public var body: some View {
    Form {
      Section {
        SettingsDurationPickerRow(
          title: "Retention Window",
          presets: Self.retentionPresetsSeconds,
          minSeconds: Self.minimumRetentionSeconds,
          seconds: retentionBinding,
          pickerAccessibilityIdentifier:
            HarnessMonitorAccessibility.settingsSupervisorPane("audit-retention")
        )
        Text(
          """
          Compaction drops supervisor events and resolved decisions older than the retention \
          window. Open decisions are never dropped automatically.
          """
        )
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Retention")
          .harnessNativeFormSectionHeader()
      } footer: {
        Text("Retention applies to both supervisor events and resolved decisions")
          .harnessNativeFormSectionFooter()
      }

      Section {
        Text("Audit timeline coming soon — see View → Audit Timeline")
          .scaledFont(.callout)
          .foregroundStyle(.secondary)
        // TODO(audit-timeline/unit-4): route to the audit timeline window once
        // Unit 4 wires it up. The button is a placeholder until that lands.
        Button("Open Audit Timeline") {}
          .disabled(true)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsSupervisorPane("audit-open-timeline")
          )
      } header: {
        Text("Timeline")
          .harnessNativeFormSectionHeader()
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsSupervisorPane("audit")
    )
  }

  // MARK: - Bridging

  /// Bridges the view model's `TimeInterval` retention to the `UInt64` seconds the
  /// duration picker requires. Negative or non-finite values are clamped to the
  /// minimum retention before being committed back to the view model.
  private var retentionBinding: Binding<UInt64> {
    Binding(
      get: { Self.unsignedSeconds(from: viewModel.retentionSeconds) },
      set: { newValue in
        viewModel.retentionSeconds = TimeInterval(newValue)
      }
    )
  }

  private static func unsignedSeconds(from interval: TimeInterval) -> UInt64 {
    guard interval.isFinite, interval > 0 else { return minimumRetentionSeconds }
    return UInt64(interval.rounded())
  }

  // MARK: - Presets

  static let minimumRetentionSeconds: UInt64 = 24 * 60 * 60
  static let retentionPresetsSeconds: [UInt64] = [
    24 * 60 * 60,
    7 * 24 * 60 * 60,
    14 * 24 * 60 * 60,
    30 * 24 * 60 * 60,
    90 * 24 * 60 * 60,
  ]
}
