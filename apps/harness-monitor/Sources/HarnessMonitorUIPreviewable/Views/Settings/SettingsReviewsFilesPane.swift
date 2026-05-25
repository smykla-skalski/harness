import HarnessMonitorKit
import SwiftUI

struct SettingsReviewsFilesPane: View {
  let isActive: Bool
  @Binding var draft: DashboardReviewsPreferences

  init(
    draft: Binding<DashboardReviewsPreferences>,
    isActive: Bool = true
  ) {
    self.isActive = isActive
    _draft = draft
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      Section {
        SettingsReviewsFilesSection(draft: $draft)
      } header: {
        Text("Files").harnessNativeFormSectionHeader()
      }
      .accessibilityIdentifier("settingsReviewFilesSection")
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsPane("files"))
  }
}
