import SwiftData

public enum ReviewFileStoreDefaults {
  public static func preview() -> ReviewFilePreviewStore {
    ReviewFilePreviewStore(directory: HarnessMonitorPaths.reviewFilePreviewCacheRoot())
  }

  public static func patch() -> ReviewFilePatchStore {
    ReviewFilePatchStore(
      directory: HarnessMonitorPaths.generatedCacheRoot()
        .appendingPathComponent("review-file-patches", isDirectory: true)
    )
  }
}

extension HarnessMonitorStore {
  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil,
    reviewFilePreviewStore: ReviewFilePreviewStore = ReviewFileStoreDefaults.preview(),
    reviewFilePatchStore: ReviewFilePatchStore = ReviewFileStoreDefaults.patch()
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
      reviewFilePreviewStore: reviewFilePreviewStore,
      reviewFilePatchStore: reviewFilePatchStore
    )
  }
}
