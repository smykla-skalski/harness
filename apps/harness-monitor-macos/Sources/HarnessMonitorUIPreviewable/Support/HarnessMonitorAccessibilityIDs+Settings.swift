extension HarnessMonitorAccessibility {
  public static let settingsRoot = "harness.settings.root"
  public static let settingsState = "harness.settings.state"
  public static let settingsPanel = "harness.settings.panel"
  public static let settingsToolbarSeparatorSuppressed =
    "harness.settings.toolbar.separator-suppressed"
  public static let settingsSidebar = "harness.settings.sidebar"
  public static let settingsBackButton = "harness.settings.nav.back"
  public static let settingsForwardButton = "harness.settings.nav.forward"
  public static let settingsTitle = "harness.settings.title"
  public static let settingsThemeModePicker = "harness.settings.theme-mode"
  public static let settingsBackdropModePicker = "harness.settings.backdrop-mode"
  public static let settingsLaunchBehaviorPicker = "harness.settings.launch-behavior"
  public static let settingsBackgroundCollectionPicker =
    "harness.settings.background-collection"
  public static let settingsBackgroundGallery = "harness.settings.background-gallery"
  public static let settingsBackgroundRecentsSection =
    "harness.settings.background.recents-section"
  public static let settingsBackgroundRecentState =
    "harness.settings.background.recents-state"
  public static let settingsTextSizePicker = "harness.settings.text-size"
  public static let settingsMenuBarStateColorsToggle =
    "harness.settings.menu-bar.state-colors"
  public static let settingsSessionShortcutOverlaysToggle =
    "harness.settings.session.shortcut-overlays"
  public static let settingsSessionTitleBlurToggle =
    "harness.settings.session.title-blur"
  public static let settingsSessionRowModePicker =
    "harness.settings.sidebar-session-row-mode"
  public static let settingsTimeZoneModePicker = "harness.settings.time-zone-mode"
  public static let settingsCustomTimeZonePicker = "harness.settings.custom-time-zone"
  public static let settingsTimelinePersistencePicker =
    "harness.settings.timeline.filter-persistence"
  public static let settingsPendingDecisionBannersToggle =
    "harness.settings.decisions.pending-banners"
  public static let settingsPendingBannersFocusModeToggle =
    "harness.settings.decisions.pending-banners.focus-mode"
  public static let settingsMCPSection = "harness.settings.mcp"
  public static let settingsMCPRegistryHostToggle =
    "harness.settings.mcp.registry-host"
  public static let settingsMCPStatus = "harness.settings.mcp.status"
  public static let settingsLaunchAgentRepairButton =
    "harness.settings.diagnostics.launch-agent.repair"
  public static let settingsVoiceSection = "harness.settings.voice"
  public static let settingsVoiceLocaleField = "harness.settings.voice.locale-field"
  public static let settingsVoiceLocalePicker = "harness.settings.voice.locale-picker"
  public static let settingsVoiceLocalDaemonToggle = "harness.settings.voice.local-daemon"
  public static let settingsVoiceAgentBridgeToggle = "harness.settings.voice.agent-bridge"
  public static let settingsVoiceRemoteProcessorToggle =
    "harness.settings.voice.remote-processor"
  public static let settingsVoiceRemoteProcessorURLField =
    "harness.settings.voice.remote-processor-url"
  public static let settingsVoiceInsertionModePicker =
    "harness.settings.voice.insertion-mode"
  public static let settingsVoiceAudioChunksToggle = "harness.settings.voice.audio-chunks"
  public static let settingsVoicePendingAudioField =
    "harness.settings.voice.pending-audio-limit"
  public static let settingsVoicePendingTranscriptField =
    "harness.settings.voice.pending-transcript-limit"
  public static let settingsVoiceStatus = "harness.settings.voice.status"
  public static let settingsNotificationsStatus = "harness.settings.notifications.status"
  public static let settingsNotificationsPresetPicker =
    "harness.settings.notifications.preset"
  public static let settingsNotificationsCategoryPicker =
    "harness.settings.notifications.category"
  public static let settingsNotificationsSoundPicker = "harness.settings.notifications.sound"
  public static let settingsNotificationsAttachmentPicker =
    "harness.settings.notifications.attachment"
  public static let settingsNotificationsTriggerPicker =
    "harness.settings.notifications.trigger"
  public static let settingsNotificationsSendButton = "harness.settings.notifications.send"

  public static let settingsTaskBoardRoot = "harness.settings.task-board"
  public static let settingsTaskBoardStatus = "harness.settings.task-board.status"
  public static let settingsTaskBoardReloadButton = "harness.settings.task-board.reload"
  public static let settingsTaskBoardSaveButton = "harness.settings.task-board.save"
  public static let settingsTaskBoardProjectDirField = "harness.settings.task-board.project-dir"
  public static let settingsTaskBoardOwnerField = "harness.settings.task-board.owner"
  public static let settingsTaskBoardRepoField = "harness.settings.task-board.repo"
  public static let settingsTaskBoardInboxRepositoriesField =
    "harness.settings.task-board.github-inbox.repositories"
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
  public static let settingsTaskBoardTodoistTokenField =
    "harness.settings.task-board.todoist-token"
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

  public static func settingsAuthorizedFolderRow(_ id: String) -> String {
    "harness.settings.authorized-folders.row.\(id)"
  }

  public static func segmentedOption(_ controlID: String, option: String) -> String {
    "\(controlID).option.\(slug(option))"
  }
}
