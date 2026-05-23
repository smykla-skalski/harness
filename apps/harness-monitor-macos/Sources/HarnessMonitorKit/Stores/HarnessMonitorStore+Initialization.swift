import SwiftData

extension HarnessMonitorStore {
  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil,
    reviewFilePreviewStore: ReviewFilePreviewStore = ReviewFilePreviewStore(
      directory: HarnessMonitorPaths.reviewFilePreviewCacheRoot()
    )
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: voiceCapture,
      daemonOwnership: daemonOwnership,
      modelContainer: modelContainer,
      persistenceError: persistenceError,
      cacheService: cacheService,
      taskBoardSettingsWorker: TaskBoardSettingsWorker(),
      reviewFilePreviewStore: reviewFilePreviewStore
    )
  }
}
