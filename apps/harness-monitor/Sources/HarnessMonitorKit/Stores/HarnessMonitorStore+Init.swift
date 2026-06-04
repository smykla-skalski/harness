import Observation
import SwiftData

extension HarnessMonitorStore {
  init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil,
    taskBoardSettingsWorker: TaskBoardSettingsWorker,
    reviewFilePreviewStore: ReviewFilePreviewStore = ReviewFileStoreDefaults.preview(),
    reviewFilePatchStore: ReviewFilePatchStore = ReviewFileStoreDefaults.patch()
  ) {
    self.connection = ConnectionSlice()
    self.sessionIndex = SessionIndexSlice()
    self.selection = SelectionSlice()
    self.userData = UserDataSlice()
    self.contentUI = ContentUISlice()
    self.sidebarUI = SidebarUISlice()
    self.toast = ToastSlice()
    self.supervisorToolbarSlice = SupervisorToolbarSlice()
    self.bookmarkStore = Self.makeBookmarkStore()
    self.daemonController = daemonController
    self.daemonOwnership = daemonOwnership
    self.fileViewer = fileViewer
    self.voiceCapture = voiceCapture
    self.taskBoardSettingsWorker = taskBoardSettingsWorker
    self.reviewFilePreviewStore = reviewFilePreviewStore
    self.reviewFilePatchStore = reviewFilePatchStore
    self.modelContext = modelContainer?.mainContext
    self.userDataService = modelContainer.map {
      UserDataPersistenceService(
        modelContainer: $0,
        maxRecentSearches: Self.maxRecentSearches
      )
    }
    self.supervisorPolicyConfigRepository = modelContainer.map(
      SupervisorPolicyConfigRepository.init)
    self.supervisorAuditRepository = modelContainer.map(SupervisorAuditRepository.init)
    if let cacheService {
      self.cacheService = cacheService
    } else if let modelContainer {
      self.cacheService = SessionCacheService(
        modelContainer: modelContainer,
        databaseURL: HarnessMonitorPaths.cacheStoreURL()
      )
    } else {
      self.cacheService = nil
    }
    self.persistenceError = persistenceError
    applyEnvironmentConfigurationAndStartInitialWork()
  }
}
