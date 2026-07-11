import SwiftUI

struct SettingsTaskBoardCardsSection: View {
  @AppStorage(TaskBoardCardPreferences.priorityBadgeVisibilityStorageKey)
  private var showsPriorityBadge = TaskBoardCardPreferences.defaultShowsPriorityBadge

  var body: some View {
    Section {
      Toggle("Priority Badge", isOn: $showsPriorityBadge)
    } header: {
      Text("Cards")
        .harnessNativeFormSectionHeader()
    }
  }
}
