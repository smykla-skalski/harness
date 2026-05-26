import SwiftUI

struct PolicyCanvasAutomationPolicySheet: View {
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      SettingsPoliciesSection(isActive: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 680, idealHeight: 760)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Automation Policies")
          .scaledFont(.headline.weight(.semibold))
        Text("Configure clipboard, paste, drop, file picker, and screenshot OCR behavior")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXL)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
  }
}
