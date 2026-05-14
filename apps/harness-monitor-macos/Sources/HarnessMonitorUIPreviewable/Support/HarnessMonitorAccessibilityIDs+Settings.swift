extension HarnessMonitorAccessibility {
  public static let settingsTaskBoardRoot = "harness.settings.task-board"
  public static let settingsTaskBoardStatus = "harness.settings.task-board.status"
  public static let settingsTaskBoardReloadButton = "harness.settings.task-board.reload"
  public static let settingsTaskBoardSaveButton = "harness.settings.task-board.save"
  public static let settingsTaskBoardProjectDirField = "harness.settings.task-board.project-dir"
  public static let settingsTaskBoardOwnerField = "harness.settings.task-board.owner"
  public static let settingsTaskBoardRepoField = "harness.settings.task-board.repo"
  public static let settingsTaskBoardCheckoutPathField = "harness.settings.task-board.checkout-path"
  public static let settingsTaskBoardProtectedPathsField =
    "harness.settings.task-board.protected-paths"
  public static let settingsTaskBoardSSHKeyPathField = "harness.settings.task-board.ssh-key-path"
  public static let settingsTaskBoardSigningSSHKeyPathField =
    "harness.settings.task-board.signing-ssh-key-path"
  public static let settingsTaskBoardGPGKeyIDField = "harness.settings.task-board.gpg-key-id"
  public static let settingsTaskBoardGPGPrivateKeyPathField =
    "harness.settings.task-board.gpg-private-key-path"
  public static let settingsTaskBoardGPGPassphraseField =
    "harness.settings.task-board.gpg-private-key-passphrase"
  public static let settingsTaskBoardGlobalTokenField = "harness.settings.task-board.global-token"
  public static let settingsTaskBoardAddOverrideButton = "harness.settings.task-board.override.add"

  public static func settingsSectionButton(_ key: String) -> String {
    "harness.settings.section.\(slug(key))"
  }

  public static func settingsActionButton(_ key: String) -> String {
    "harness.settings.action.\(slug(key))"
  }

  public static func settingsAcpPermissionLogRevealButton(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal.\(slug(runID))"
  }

  public static func settingsAcpPermissionLogError(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.error.\(slug(runID))"
  }

  public static func settingsAcpPermissionLogRevealStatus(_ runID: String) -> String {
    "harness.settings.diagnostics.acp-permission-log.reveal-status.\(slug(runID))"
  }

  public static func settingsBackgroundTile(_ key: String) -> String {
    "harness.settings.background.\(slug(key))"
  }

  public static func settingsTaskBoardRepositoryOverrideField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).repository"
  }

  public static func settingsTaskBoardRepositoryOverrideTokenField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).token"
  }

  public static func settingsTaskBoardRepositoryOverrideSSHKeyField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).ssh-key-path"
  }

  public static func settingsTaskBoardRepositoryOverrideSigningSSHKeyField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).signing-ssh-key-path"
  }

  public static func settingsTaskBoardRepositoryOverrideGPGPrivateKeyField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).gpg-private-key-path"
  }

  public static func settingsTaskBoardRepositoryOverrideGPGPassphraseField(_ index: Int) -> String {
    "harness.settings.task-board.override.\(index).gpg-private-key-passphrase"
  }

  public static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
