import SwiftUI

struct SettingsTaskBoardCardsSection: View {
  @AppStorage(TaskBoardCardPreferences.priorityBadgeVisibilityStorageKey)
  private var showsPriorityBadge = TaskBoardCardPreferences.defaultShowsPriorityBadge
  @AppStorage(TaskBoardCardPreferences.fullRepositoryNamesStorageKey)
  private var alwaysShowsFullRepositoryNames =
    TaskBoardCardPreferences.defaultAlwaysShowsFullRepositoryNames

  var body: some View {
    Section {
      Toggle("Priority Badge", isOn: $showsPriorityBadge)
      Toggle("Full Repository Names", isOn: $alwaysShowsFullRepositoryNames)
        .help("Always show repository owners on Task Board cards")
    } header: {
      Text("Cards")
        .harnessNativeFormSectionHeader()
    }
  }
}
