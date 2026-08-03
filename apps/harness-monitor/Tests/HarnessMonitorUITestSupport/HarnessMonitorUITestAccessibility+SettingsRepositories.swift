extension HarnessMonitorUITestAccessibility {
  static let settingsRepositoriesRoot = "harness.settings.repositories"
  static let settingsRepositoriesReloadButton = "harness.settings.repositories.reload"
  static let settingsRepositoriesSaveButton = "harness.settings.repositories.save"
  static let settingsRepositoriesOwnerField = "harness.settings.repositories.owner"
  static let settingsRepositoriesNameField = "harness.settings.repositories.name"
  static let settingsRepoTaskBoardScopeSummary =
    "harness.settings.repositories.task-board.scope.summary"
  static let settingsRepoTaskBoardEnableAllButton =
    "harness.settings.repositories.task-board.enable-all"
  static let settingsRepoTaskBoardDisableAllButton =
    "harness.settings.repositories.task-board.disable-all"

  static func settingsRepositoriesRow(_ index: Int) -> String {
    "harness.settings.repositories.\(index).row"
  }

  static func settingsRepositoriesReviewsToggle(_ index: Int) -> String {
    "harness.settings.repositories.\(index).reviews"
  }

  static func settingsRepositoriesTaskBoardToggle(_ index: Int) -> String {
    "harness.settings.repositories.\(index).task-board"
  }

  static func settingsRepositoriesTaskBoardOnlyButton(_ index: Int) -> String {
    "harness.settings.repositories.\(index).task-board.only"
  }

  static func settingsRepositoriesOverridesDisclosure(_ index: Int) -> String {
    "harness.settings.repositories.\(index).overrides"
  }

  static func settingsRepositoriesOverrideToggle(_ index: Int, _ kind: String) -> String {
    "harness.settings.repositories.\(index).overrides.\(kind)"
  }
}
