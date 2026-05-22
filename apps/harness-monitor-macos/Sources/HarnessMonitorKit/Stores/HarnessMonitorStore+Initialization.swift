import SwiftData

extension HarnessMonitorStore {
  public convenience init(
    daemonController: any DaemonControlling,
    fileViewer: any FileViewerActivating = WorkspaceFileViewer(),
    voiceCapture: any VoiceCaptureProviding,
    daemonOwnership: DaemonOwnership = .managed,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    cacheService: SessionCacheService? = nil
  ) {
    self.init(
      daemonController: daemonController,
      fileViewer: fileViewer,
      voiceCapture: voiceCapture,
      daemonOwnership: daemonOwnership,
      modelContainer: modelContainer,
      persistenceError: persistenceError,
      cacheService: cacheService,
      taskBoardSettingsWorker: TaskBoardSettingsWorker()
    )
  }
}
