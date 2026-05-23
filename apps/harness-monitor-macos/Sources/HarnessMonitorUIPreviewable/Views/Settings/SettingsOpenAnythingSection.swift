import HarnessMonitorKit
import SwiftUI

/// Settings section for the Open Anything command palette. Owns the global
/// hotkey controls (lifted out of the Windows section, audit item #34) plus the
/// behavior toggles that other Open Anything units consume (audit items #74,
/// #75, #94, #95).
struct SettingsOpenAnythingSection: View {
  @AppStorage(OpenAnythingHotKeyDefaults.enabledKey)
  private var globalHotKeyEnabled = OpenAnythingHotKeyDefaults.enabledDefault
  @AppStorage(OpenAnythingHotKeyDefaults.descriptorKey)
  private var globalHotKeyDescriptor =
    OpenAnythingHotKeyDefaults.descriptorDefault.storageValue
  @AppStorage(OpenAnythingPreferencesDefaults.showPinnedKey)
  private var showPinned = OpenAnythingPreferencesDefaults.showPinnedDefault
  @AppStorage(OpenAnythingPreferencesDefaults.showRecentKey)
  private var showRecent = OpenAnythingPreferencesDefaults.showRecentDefault
  @AppStorage(OpenAnythingPreferencesDefaults.cmdClickBackgroundKey)
  private var cmdClickBackground =
    OpenAnythingPreferencesDefaults.cmdClickBackgroundDefault
  @AppStorage(OpenAnythingPreferencesDefaults.restoreLastQueryKey)
  private var restoreLastQuery =
    OpenAnythingPreferencesDefaults.restoreLastQueryDefault
  @AppStorage(OpenAnythingPreferencesDefaults.perDomainLimitKey)
  private var perDomainLimit = OpenAnythingPreferencesDefaults.perDomainLimitDefault
  @AppStorage(OpenAnythingPreferencesDefaults.scopeToWindowKey)
  private var scopeToWindow = OpenAnythingPreferencesDefaults.scopeToWindowDefault

  var body: some View {
    Section {
      OpenAnythingHotKeySettingsView(
        isEnabled: $globalHotKeyEnabled,
        descriptorStorage: $globalHotKeyDescriptor
      )
      Toggle("Show pinned items first", isOn: $showPinned)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingShowPinnedToggle)
        .accessibilityHint(
          "When enabled, pinned palette entries surface above ranked results."
        )
      Toggle("Show recently used", isOn: $showRecent)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingShowRecentToggle)
        .accessibilityHint(
          "When enabled, the palette shows a recently used lane on empty queries."
        )
      Toggle("Cmd+Click opens in background", isOn: $cmdClickBackground)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.openAnythingCmdClickBackgroundToggle
        )
        .accessibilityHint(
          "When enabled, Command-click activates a hit without bringing its window to the front."
        )
      Toggle("Restore last query when reopening", isOn: $restoreLastQuery)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.openAnythingRestoreLastQueryToggle
        )
        .accessibilityHint(
          "When enabled, reopening the palette restores the previous search query."
        )
      Toggle("Scope to current window", isOn: $scopeToWindow)
        .accessibilityHint(
          "When enabled, the palette scopes results to the kind of window you opened it from."
        )
      Stepper(value: $perDomainLimit, in: perDomainLimitRange) {
        Text("Results per section: \(perDomainLimit)")
      }
      .accessibilityHint(
        "Caps how many hits each section in the palette shows before scrolling."
      )
    } header: {
      Text("Open Anything")
    } footer: {
      footerText
    }
  }

  private var perDomainLimitRange: ClosedRange<Int> {
    OpenAnythingPreferencesDefaults
      .perDomainLimitMin...OpenAnythingPreferencesDefaults.perDomainLimitMax
  }

  @ViewBuilder private var footerText: some View {
    Text(
      "Open Anything is the command palette opened with ⌘K. "
        + "The global hotkey activates it from anywhere on the system."
    )
  }
}
